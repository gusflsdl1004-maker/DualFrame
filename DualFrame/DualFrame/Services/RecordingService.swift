//
//  RecordingService.swift
//  DualFrame
//

import AVFoundation

/// Lifecycle states for a single recording.
/// `nonisolated` because it's compared from within `RecordingService`'s own actor context,
/// not the default main-actor isolation this project applies to unannotated types.
nonisolated enum RecordingState: Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case finished
    case failed
}

enum RecordingServiceError: Error {
    case writerCreationFailed
    case cannotAddInput
}

/// Owns the `AVAssetWriter` pipeline: creates the writer and inputs, appends sample
/// buffers forwarded from `CameraService`, and finishes the file safely.
/// No gallery saving, dual recording, or automatic recovery happens here.
actor RecordingService {
    private(set) var state: RecordingState = .idle
    private(set) var lastError: Error?

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var isSessionStarted = false

    @discardableResult
    func prepareRecording() async -> RecordingState {
        guard state == .idle || state == .finished || state == .failed else { return state }
        state = .preparing
        lastError = nil

        do {
            try setUpWriter()
        } catch {
            lastError = error
            state = .failed
        }
        return state
    }

    @discardableResult
    func startRecording() async -> RecordingState {
        guard state == .preparing, assetWriter != nil else { return state }
        state = .recording
        return state
    }

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        await append(sampleBuffer, to: videoInput)
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        await append(sampleBuffer, to: audioInput)
    }

    @discardableResult
    func stopRecording() async -> RecordingState {
        guard state == .recording else { return state }
        state = .stopping

        guard let writer = assetWriter, isSessionStarted else {
            // Nothing was ever written (e.g. stopped before the first sample buffer arrived).
            state = .failed
            return state
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .completed {
            state = .finished
        } else {
            lastError = writer.error
            state = .failed
        }
        return state
    }

    /// The finished recording's file URL, if the last recording completed successfully.
    func outputFileURL() -> URL? {
        state == .finished ? outputURL : nil
    }

    private func setUpWriter() throws {
        let url = Self.makeOutputURL()
        let writer = try AVAssetWriter(url: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080
        ]
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000
        ]
        let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioWriterInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoWriterInput) else { throw RecordingServiceError.cannotAddInput }
        writer.add(videoWriterInput)

        guard writer.canAdd(audioWriterInput) else { throw RecordingServiceError.cannotAddInput }
        writer.add(audioWriterInput)

        assetWriter = writer
        videoInput = videoWriterInput
        audioInput = audioWriterInput
        outputURL = url
        isSessionStarted = false
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) async {
        guard state == .recording, let writer = assetWriter, let input else { return }

        if !isSessionStarted {
            guard writer.startWriting() else {
                lastError = writer.error
                state = .failed
                return
            }
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: startTime)
            isSessionStarted = true
        }

        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)

        if writer.status == .failed {
            lastError = writer.error
            state = .failed
        }
    }

    private static func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
    }
}
