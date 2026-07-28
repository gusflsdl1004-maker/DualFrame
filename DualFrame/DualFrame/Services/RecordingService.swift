//
//  RecordingService.swift
//  DualFrame
//

import AVFoundation

/// Lifecycle states for a single recording.
/// `nonisolated` because it's compared from within `RecordingService`'s own actor context,
/// not the default main-actor isolation this project applies to unannotated types.
nonisolated enum RecordingState: Equatable, Codable {
    case idle
    case preparing
    case recording
    case stopping
    case finished
    case failed
}

/// Owns the `AVAssetWriter` pipeline(s): creates the writer(s) and inputs, appends
/// sample buffers forwarded from `CameraService`, finishes the file(s) safely, and
/// validates them with `RecordingValidator` before reporting success. Also persists a
/// periodic `RecordingCheckpoint` (crash-recovery preparation only — no automatic
/// recovery happens here; see CLAUDE.md rules 21-24).
///
/// In `.single` mode (the default, and the only mode that existed before Task 019) this
/// drives exactly one writer, built from the user's `activeQuality`/`activeFPS`
/// preference — byte-for-byte the same behavior as before Task 019 (requirement 9).
/// In `.dual` mode it drives two independent writers, one per `OutputProfile.longForm`
/// and `.shortForm`, that share the same `recordingStartTime` and session-start
/// timestamp but otherwise fail, finish, and validate independently (requirements 4-7).
actor RecordingService {
    /// Everything tied to one active `AVAssetWriter` session: the writer, its inputs,
    /// output location, whether its session has started, and whether it has failed.
    /// `hasFailed` is per-writer (Task 019 requirement 6) — a failure here never
    /// touches any other active `WriterContext`; only when every context has failed
    /// does the overall `state` become `.failed` (see `append(_:isVideo:)`).
    private struct WriterContext {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput
        let outputURL: URL
        var isSessionStarted = false
        var hasFailed = false
        /// Non-nil only for the short-form output (Task 021) — long-form and `.single`
        /// mode leave both of these `nil`, so `append(_:isVideo:)` takes the exact same
        /// unmodified-sample-buffer path it always has for them.
        var cropConfiguration: CropConfiguration?
        var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    }

    private(set) var state: RecordingState = .idle
    /// Mirrors the single active profile's error/result in `.single` mode exactly as
    /// before Task 019. In `.dual` mode these reflect whichever profile was processed
    /// most recently in `stopRecording(expectsAudioTrack:)` — UI code for dual mode
    /// should read `writerStatuses` instead, which is per-profile.
    private(set) var lastError: RecordingError?
    private(set) var lastValidationResult: RecordingValidationResult?
    private(set) var lastImportedRecord: VideoRecord?
    /// True while recording is paused due to an interruption. `state` deliberately
    /// stays `.recording` while paused — pausing is a temporary, resumable condition,
    /// not a terminal one, and the existing Stop button must keep working regardless.
    private(set) var isPaused = false

    /// Which mode the *next* `prepareRecording()` call builds writers for. Set via
    /// `configureMode(_:)` before preparing — changing it mid-recording has no effect
    /// on a recording already in progress.
    private(set) var mode: RecordingMode = .single

    /// One status per currently active `OutputProfile`, updated independently as each
    /// writer starts, fails, or finishes (requirement 8). In `.single` mode this always
    /// has exactly one entry, keyed by an ad-hoc profile built from `activeQuality`/
    /// `activeFPS` — nothing outside this actor needs to know that key, since single-mode
    /// UI already reads the mirrored `state`/`lastError`/`lastValidationResult` above.
    private(set) var writerStatuses: [OutputProfile: DualWriterStatus] = [:]

    private let validator = RecordingValidator()
    private let libraryService: InternalVideoLibraryService
    /// `nonisolated` because these are just references to other actors — safe to hand
    /// out (actors are inherently `Sendable`) without crossing this actor's isolation.
    nonisolated let performanceMonitor = RecordingPerformanceMonitor()
    nonisolated let checkpointStore = RecordingCheckpointStore()
    /// Only ever invoked for the short-form output's video (see `append`) — never for
    /// long-form or `.single` mode.
    private let frameCropper = VideoFrameCropper()

    private var writerContexts: [OutputProfile: WriterContext] = [:]
    private(set) var activeQuality: RecordingQuality = .fullHD
    private(set) var activeFPS: RecordingFPS = .fps30
    private var lastAppendedTimestamp: CMTime = .zero
    private(set) var recordingStartTime: Date?
    private var checkpointTask: Task<Void, Never>?
    /// How many times a checkpoint was actually saved during the current/last
    /// recording — surfaced in the diagnostics report.
    private(set) var checkpointSaveCount = 0

    init(libraryService: InternalVideoLibraryService) {
        self.libraryService = libraryService
    }

    /// Called by `CameraService` once it has resolved the actual capture resolution
    /// and frame rate (which may differ from the user's raw preference if a fallback
    /// occurred), so the asset writer and recovery checkpoint always reflect what the
    /// session is really running at. Only affects `.single` mode's writer — `.dual`
    /// mode's two writers always use their fixed `OutputProfile` dimensions.
    func updateRecordingFormat(quality: RecordingQuality, fps: RecordingFPS) {
        activeQuality = quality
        activeFPS = fps
    }

    /// Selects which mode the next `prepareRecording()` builds writers for
    /// (requirement 1). Call before `prepareRecording()` — has no effect once a
    /// recording is already prepared or in progress.
    func configureMode(_ mode: RecordingMode) {
        guard state == .idle || state == .finished || state == .failed else { return }
        self.mode = mode
    }

    @discardableResult
    func prepareRecording() async -> RecordingState {
        guard state == .idle || state == .finished || state == .failed else { return state }
        state = .preparing
        lastError = nil
        lastValidationResult = nil
        lastImportedRecord = nil
        lastAppendedTimestamp = .zero
        recordingStartTime = nil
        isPaused = false
        checkpointSaveCount = 0

        // Warn-only check (requirement 13) — never blocks preparing or recording.
        await performanceMonitor.checkAvailableStorage()

        setUpWriters()

        // Requirement 6/9: only fail overall if *every* target profile's writer could
        // not be created. In `.single` mode there is exactly one target profile, so
        // this reduces to the original single-writer failure behavior exactly.
        guard !writerContexts.isEmpty else {
            lastError = .writerCreationFailed
            state = .failed
            return state
        }
        return state
    }

    @discardableResult
    func startRecording() async -> RecordingState {
        guard state == .preparing, !writerContexts.isEmpty else { return state }
        state = .recording
        isPaused = false
        recordingStartTime = Date()
        for profile in writerContexts.keys {
            writerStatuses[profile]?.state = .recording
        }
        await performanceMonitor.startMonitoring()
        await saveCheckpoint()
        startCheckpointing()
        return state
    }

    /// Stops accepting new sample buffers without finishing the file(s), so whatever was
    /// captured before the interruption stays intact and a future resume feature could
    /// continue writing to the same session(s). Preserves a checkpoint immediately
    /// (requirement 6) — this is the closest we can get to "before the interruption"
    /// since we can only react once the OS notification arrives.
    func pauseRecording() async {
        guard state == .recording, !isPaused else { return }
        isPaused = true
        await saveCheckpoint()
    }

    /// Extension point for a future "Resume Recording" feature (requirement 8). Nothing
    /// in this task calls this automatically or wires it to any UI — recording stays
    /// paused until the user manually stops it, unless a later task adds a resume button.
    func resumeRecording() async {
        guard state == .recording, isPaused else { return }
        isPaused = false
    }

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        await append(sampleBuffer, isVideo: true)
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        await append(sampleBuffer, isVideo: false)
    }

    /// Finishes writing and validates each active writer's file independently
    /// (requirement 7) — a failure in one never skips or cancels another.
    /// `expectsAudioTrack` should reflect whether microphone permission was granted —
    /// a missing audio track is only an error when audio was actually expected.
    @discardableResult
    func stopRecording(expectsAudioTrack: Bool) async -> RecordingState {
        guard state == .recording else { return state }
        state = .stopping
        stopCheckpointing()
        await performanceMonitor.stopMonitoring()

        var anySucceeded = false

        for profile in writerContexts.keys {
            guard let context = writerContexts[profile] else { continue }
            writerStatuses[profile]?.state = .stopping

            guard !context.hasFailed, context.isSessionStarted else {
                // Nothing was ever written (e.g. stopped before the first sample buffer
                // arrived), or this writer already failed mid-recording. Requirement 6:
                // this never stops the loop — every other profile still gets processed.
                let error = writerStatuses[profile]?.lastError ?? .writeFailed
                writerStatuses[profile]?.state = .failed
                writerStatuses[profile]?.lastError = error
                lastError = error
                continue
            }

            context.videoInput.markAsFinished()
            context.audioInput.markAsFinished()

            await withCheckedContinuation { continuation in
                context.writer.finishWriting {
                    continuation.resume()
                }
            }

            guard context.writer.status == .completed else {
                writerStatuses[profile]?.state = .failed
                writerStatuses[profile]?.lastError = .writeFailed
                lastError = .writeFailed
                continue
            }

            // Requirement 7: validated independently per profile.
            let result = await validator.validate(fileURL: context.outputURL, expectsAudioTrack: expectsAudioTrack)
            writerStatuses[profile]?.validationResult = result
            lastValidationResult = result

            guard result.isValid else {
                let error = result.error ?? .validationFailed
                writerStatuses[profile]?.state = .failed
                writerStatuses[profile]?.lastError = error
                lastError = error
                continue
            }

            do {
                // Moves the file out of the temporary directory — nothing stays there
                // once a recording succeeds.
                let imported = try await libraryService.importRecording(from: context.outputURL, validation: result)
                writerStatuses[profile]?.state = .finished
                lastImportedRecord = imported
                anySucceeded = true
            } catch {
                writerStatuses[profile]?.state = .failed
                writerStatuses[profile]?.lastError = .unknown
                lastError = .unknown
            }
        }

        if anySucceeded {
            state = .finished
            // Requirement 7 (Task 018): only a successful completion clears the
            // checkpoint. In dual mode this fires as long as at least one output
            // succeeded — rule 1: never lose recorded video just because its sibling
            // output failed.
            await checkpointStore.delete()
        } else {
            state = .failed
        }
        return state
    }

    /// The finished recording's permanent file URL in the internal library, if the last
    /// recording completed, validated, and was imported successfully. In `.dual` mode
    /// this is whichever profile's import happened last — use `writerStatuses` for a
    /// per-profile result.
    func outputFileURL() -> URL? {
        lastImportedRecord?.localURL
    }

    /// The `OutputProfile`s this recording should target, given the current `mode`.
    /// `.single` always yields exactly one ad-hoc profile built from the user's
    /// `activeQuality`/`activeFPS` — never `.longForm`, which has fixed dimensions that
    /// would silently override the user's quality/FPS choice (requirement 9).
    private var targetProfiles: [OutputProfile] {
        switch mode {
        case .single:
            [singleModeProfile()]
        case .dual:
            [.longForm, .shortForm]
        }
    }

    private func singleModeProfile() -> OutputProfile {
        let dimensions = activeQuality.dimensions
        return OutputProfile(
            outputName: "Single",
            resolution: OutputResolution(width: dimensions.width, height: dimensions.height),
            fps: activeFPS,
            aspectRatio: .widescreen
        )
    }

    /// Creates a `WriterContext` per target profile, independently — one profile's
    /// `AVAssetWriter` creation failing never prevents another's (requirement 6). Only
    /// profiles that succeed end up in `writerContexts`/`writerStatuses`.
    private func setUpWriters() {
        writerContexts = [:]
        writerStatuses = [:]

        for profile in targetProfiles {
            do {
                writerContexts[profile] = try makeWriterContext(for: profile)
                writerStatuses[profile] = DualWriterStatus(state: .preparing)
            } catch {
                writerStatuses[profile] = DualWriterStatus(state: .failed, lastError: .writerCreationFailed)
            }
        }
    }

    private func makeWriterContext(for profile: OutputProfile) throws -> WriterContext {
        let url = Self.makeOutputURL()
        let writer = try AVAssetWriter(url: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: profile.resolution.width,
            AVVideoHeightKey: profile.resolution.height
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

        guard writer.canAdd(videoWriterInput) else { throw RecordingError.writerCreationFailed }
        writer.add(videoWriterInput)

        guard writer.canAdd(audioWriterInput) else { throw RecordingError.writerCreationFailed }
        writer.add(audioWriterInput)

        // Requirement 4/5: only the short-form output is cropped. Long-form and
        // `.single` mode's ad-hoc profile are never `== .shortForm`, so they get no
        // `cropConfiguration`/`pixelBufferAdaptor` and `append` takes their original,
        // unmodified-sample-buffer path.
        var cropConfiguration: CropConfiguration?
        var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        if profile == .shortForm {
            let targetSize = CGSize(width: profile.resolution.width, height: profile.resolution.height)
            cropConfiguration = CropConfiguration(targetSize: targetSize, strategy: .center)
            let sourceAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(targetSize.width),
                kCVPixelBufferHeightKey as String: Int(targetSize.height)
            ]
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoWriterInput,
                sourcePixelBufferAttributes: sourceAttributes
            )
        }

        return WriterContext(
            writer: writer,
            videoInput: videoWriterInput,
            audioInput: audioWriterInput,
            outputURL: url,
            cropConfiguration: cropConfiguration,
            pixelBufferAdaptor: pixelBufferAdaptor
        )
    }

    /// Appends one sample buffer to every still-active writer (requirement 3). Because
    /// every writer receives the very same `CMSampleBuffer` and this loop starts each
    /// writer's session inline (not across separate calls), the first buffer of either
    /// kind to arrive sets an identical `recordingStartTime`/session-start timestamp on
    /// every writer that hasn't started yet (requirement 4) — there is no per-writer
    /// clock drift to account for.
    ///
    /// Task 021: every writer still receives the same source sample buffer, but only
    /// the short-form writer (identified by `context.cropConfiguration` being non-nil)
    /// routes its video through `frameCropper` + an `AVAssetWriterInputPixelBufferAdaptor`
    /// first, to center-crop-and-scale into its target aspect ratio instead of letting
    /// AVFoundation stretch the raw 16:9 buffer to fit. Long-form and `.single` mode
    /// never set `cropConfiguration`, so they keep appending the original, untouched
    /// sample buffer exactly as before this task. This cannot be observed running end to
    /// end in Simulator (no camera), so it has not been seen with a real capture session.
    private func append(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) async {
        // Paused means an interruption is in effect — never write new samples while
        // paused (requirement 5 from Task 017: never corrupt the existing recording).
        guard state == .recording, !isPaused else { return }

        for profile in writerContexts.keys {
            guard var context = writerContexts[profile], !context.hasFailed else { continue }
            let writer = context.writer
            let input = isVideo ? context.videoInput : context.audioInput

            if !context.isSessionStarted {
                guard writer.startWriting() else {
                    markWriterFailed(profile, error: .writeFailed)
                    continue
                }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                context.isSessionStarted = true
                writerContexts[profile] = context
            }

            guard writer.status == .writing, input.isReadyForMoreMediaData else { continue }

            let writeStart = Date()
            if isVideo, let cropConfiguration = context.cropConfiguration, let adaptor = context.pixelBufferAdaptor {
                // Task 021: the only path that differs from pre-Task-021 behavior — used
                // exclusively for the short-form output's video. `nil` from the cropper
                // means this single frame gets dropped, not that the writer failed; only
                // an actual `adaptor.append` rejection counts as a writer-level failure.
                if let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                   let croppedBuffer = frameCropper.croppedPixelBuffer(from: sourcePixelBuffer, configuration: cropConfiguration) {
                    let appended = adaptor.append(croppedBuffer, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    if !appended {
                        markWriterFailed(profile, error: .writeFailed)
                    }
                }
            } else {
                // Unchanged since before Task 021: long-form, `.single` mode, and every
                // audio append always take this exact path.
                input.append(sampleBuffer)
            }
            await performanceMonitor.recordWriteLatency(Date().timeIntervalSince(writeStart))
            lastAppendedTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if writer.status == .failed {
                markWriterFailed(profile, error: .writeFailed)
            }
        }

        // Requirement 6's boundary: only when literally every active writer has failed
        // does the overall session stop — a single writer failing must never affect the
        // others (or, in `.single` mode with its one writer, this reduces to the
        // original "any failure stops the recording" behavior).
        if !writerContexts.isEmpty, writerContexts.values.allSatisfy(\.hasFailed) {
            lastError = .writeFailed
            state = .failed
        }
    }

    private func markWriterFailed(_ profile: OutputProfile, error: RecordingError) {
        writerContexts[profile]?.hasFailed = true
        writerStatuses[profile]?.state = .failed
        writerStatuses[profile]?.lastError = error
    }

    private static func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
    }

    // MARK: - Checkpoint persistence (requirements 2-8; recovery itself is not implemented)

    /// Builds the current checkpoint from in-memory state. `nil` before a recording has
    /// actually started (nothing worth persisting yet).
    ///
    /// Dual-mode limitation (documented per CLAUDE.md rule 24): this only checkpoints
    /// the long-form output. Short-form recovery is not implemented — see the Recovery
    /// Readiness Report for what would be needed to extend this to both outputs.
    func currentCheckpoint() -> RecordingCheckpoint? {
        let primaryProfile = mode == .dual ? OutputProfile.longForm : writerContexts.keys.first
        guard let profile = primaryProfile,
              let context = writerContexts[profile],
              let startTime = recordingStartTime else { return nil }
        return RecordingCheckpoint(
            recordingState: state,
            outputURL: context.outputURL,
            recordingStartTime: startTime,
            lastSampleTimestampSeconds: lastAppendedTimestamp.seconds,
            recordingDuration: Date().timeIntervalSince(startTime),
            selectedQuality: activeQuality,
            selectedFPS: activeFPS
        )
    }

    /// Fires and does not block the caller — the checkpoint store does its own I/O
    /// on its own actor, so this never holds up sample buffer appends (requirement 6).
    private func saveCheckpoint() async {
        guard let checkpoint = currentCheckpoint() else { return }
        await checkpointStore.save(checkpoint)
        checkpointSaveCount += 1
    }

    /// Requirement 3: every 5 seconds while recording.
    private func startCheckpointing() {
        checkpointTask?.cancel()
        checkpointTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await saveCheckpoint()
            }
        }
    }

    private func stopCheckpointing() {
        checkpointTask?.cancel()
        checkpointTask = nil
    }
}
