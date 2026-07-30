//
//  ShortGenerationService.swift
//  DualFrame
//

import AVFoundation

/// Derives the short-form (9:16) output from an already-saved long-form file, after
/// recording has finished.
///
/// Task 069. This replaces the real-time short-form writer. The reason is measured, not
/// assumed: at 4K60 the long-form output alone reaches 59.47fps, adding a concurrent
/// short-form writer drops it to 51.64fps, and swapping the crop implementation
/// wholesale (CoreImage → VideoToolbox, Task 068) moved that by 0.15fps. The crop was
/// never the cost — a second writer running during capture was.
///
/// **This type can never harm a recording.** It only ever *reads* the long-form file,
/// and it does not exist until recording has stopped and that file has been validated
/// and imported. Every failure path below returns an error and leaves the source
/// untouched (CLAUDE.md rule 1, and this task's own rules 2 and 3). The output is
/// written to a temporary URL and only handed back on success, so a partial file is
/// never presented as a result.
///
/// It reuses both croppers unchanged (`FrameCropping`) — that was the point of keeping
/// them behind a protocol in Task 068. A fresh instance is created per run, so this path
/// shares no session, pool or cached state with anything else.
///
/// **Why this is faster than the real-time path could ever be:** `expectsMediaDataInRealTime`
/// is `false`, so the encoder is allowed to fall behind and catch up instead of being
/// paced by a camera that will not wait. Nothing is dropped when it does.
///
/// Extension point for Phase 5 (Auto Reframe, face tracking, other aspect ratios): the
/// per-frame decision is entirely `CropConfiguration`, passed in per call. A strategy
/// that varies the crop rect over time only needs this loop to ask for a new
/// configuration per frame — no other part of the pipeline is involved.
actor ShortGenerationService {
    private let bitrateService = BitrateEstimationService()

    /// Reads `sourceURL`, writes a cropped 9:16 file to `outputURL`.
    ///
    /// `onProgress` is called with 0...1 and may be invoked frequently; callers should
    /// assume it lands on an arbitrary executor. Cancellation is cooperative — the
    /// enclosing `Task` being cancelled stops the pass, discards the partial output, and
    /// throws `.cancelled`.
    func generate(
        from sourceURL: URL,
        to outputURL: URL,
        configuration: CropConfiguration,
        fps: RecordingFPS,
        codec: AVVideoCodecType,
        backend: CropBackend,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ShortGenerationMetrics {
        let startedAt = Date()
        let cropper: FrameCropping = backend == .videoToolbox ? VTPixelTransferCropper() : VideoFrameCropper()

        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw ShortGenerationError.noVideoTrack
        }
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            throw ShortGenerationError.sourceUnreadable
        }
        // The long-form file stores unrotated pixels plus a transform, exactly as the
        // capture buffers did. Carrying the same transform onto the short-form output
        // reproduces what the real-time path produced: crop the stored orientation,
        // then rotate as metadata (CLAUDE.md rules 52-56 — orientation is never
        // recomputed here).
        let sourceTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw ShortGenerationError.sourceUnreadable
        }
        // Ask the decoder for the same 8-bit biplanar YCbCr the capture path delivered
        // (Task 067 measured `420v`), so both croppers see the format they were built
        // and measured against.
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ShortGenerationError.sourceUnreadable }
        reader.add(videoOutput)

        // Audio is passed through rather than re-encoded: `nil` output settings on both
        // sides hand the compressed samples across untouched. Faster, and it cannot
        // degrade what was recorded.
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let writer = try? AVAssetWriter(url: outputURL, fileType: .mov) else {
            throw ShortGenerationError.writerSetupFailed
        }

        let width = Int(configuration.targetSize.width)
        let height = Int(configuration.targetSize.height)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrateService.videoBitrate(width: width, height: height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps.rawValue,
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        // The single most important line in this file. Unlike the capture path, this
        // writer is allowed to take as long as it needs per frame — the source is a
        // file, not a camera, so falling behind costs time rather than frames.
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = sourceTransform

        // `nil` attributes so the adaptor accepts whichever pixel format the selected
        // cropper produces — CoreImage emits 32BGRA, VideoToolbox emits the source's
        // own format. Neither cropper uses `adaptor.pixelBufferPool`, so declaring
        // attributes would buy nothing.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw ShortGenerationError.writerSetupFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioTrack, audioOutput != nil {
            let formatDescriptions = (try? await audioTrack.load(.formatDescriptions)) ?? []
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescriptions.first
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading(), writer.startWriting() else {
            throw ShortGenerationError.writerSetupFailed
        }
        writer.startSession(atSourceTime: .zero)

        var frameCount = 0
        var cropSeconds: TimeInterval = 0
        var encodeSeconds: TimeInterval = 0

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.pump(input: videoInput, label: "video") {
                        guard let sample = videoOutput.copyNextSampleBuffer() else { return false }
                        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return true }
                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)

                        let cropStart = Date()
                        let cropped = cropper.croppedPixelBuffer(from: sourceBuffer, configuration: configuration)
                        cropSeconds += Date().timeIntervalSince(cropStart)

                        // One unusable frame is skipped, exactly as the real-time path
                        // did — it never aborts the pass.
                        guard let cropped else { return true }

                        let encodeStart = Date()
                        let appended = adaptor.append(cropped, withPresentationTime: presentationTime)
                        encodeSeconds += Date().timeIntervalSince(encodeStart)
                        guard appended else { throw ShortGenerationError.writeFailed("video append") }

                        frameCount += 1
                        if duration.seconds > 0 {
                            onProgress(min(1, max(0, presentationTime.seconds / duration.seconds)))
                        }
                        return true
                    }
                }

                if let audioInput, let audioOutput {
                    group.addTask {
                        try await Self.pump(input: audioInput, label: "audio") {
                            guard let sample = audioOutput.copyNextSampleBuffer() else { return false }
                            return audioInput.append(sample)
                        }
                    }
                }

                try await group.waitForAll()
            }
        } catch {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            throw error is CancellationError ? ShortGenerationError.cancelled : error
        }

        if Task.isCancelled {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            throw ShortGenerationError.cancelled
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ShortGenerationError.writeFailed(writer.error.map { "\($0)" } ?? "unknown")
        }

        onProgress(1)

        // Read the frame rate back out of the file that was just written, rather than
        // reporting the rate we asked for. Same reasoning as Task 064's codec/level
        // readback: the settings dictionary says what was requested, only the file says
        // what came out. Kept separate from the long-form file's rate — the two are
        // produced by different pipelines now.
        var outputFrameRate: Float?
        if let outputTrack = try? await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video).first {
            outputFrameRate = try? await outputTrack.load(.nominalFrameRate)
        }

        return ShortGenerationMetrics(
            backend: backend,
            frameCount: frameCount,
            totalSeconds: Date().timeIntervalSince(startedAt),
            cropSeconds: cropSeconds,
            encodeSeconds: encodeSeconds,
            succeeded: true,
            // The source asset's own duration, not the recording's wall-clock length —
            // see the field's comment. This is what `speedRatio` divides by.
            sourceDurationSeconds: duration.seconds,
            outputFrameRate: outputFrameRate
        )
    }

    /// Drives one writer input from one reader output.
    ///
    /// `body` returns `false` when the source is exhausted, and may throw to abort. The
    /// loop honours `Task.isCancelled` between frames, which is what makes the user's
    /// cancel button responsive without leaving a half-written file behind — the caller
    /// deletes the output on any throw.
    private static func pump(
        input: AVAssetWriterInput,
        label: String,
        body: @escaping () throws -> Bool
    ) async throws {
        let queue = DispatchQueue(label: "com.dualframe.shortGeneration.\(label)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        input.markAsFinished()
                        continuation.resume(throwing: ShortGenerationError.cancelled)
                        return
                    }
                    do {
                        if try body() == false {
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                    } catch {
                        input.markAsFinished()
                        continuation.resume(throwing: error)
                        return
                    }
                }
            }
        }
    }
}
