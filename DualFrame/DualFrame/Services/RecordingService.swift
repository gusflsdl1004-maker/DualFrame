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

/// Owns the `AVAssetWriter` pipeline: creates the writer and inputs, appends sample
/// buffers forwarded from `CameraService`, finishes the file safely, and validates it
/// with `RecordingValidator` before reporting success. Also persists a periodic
/// `RecordingCheckpoint` (crash-recovery preparation only — no automatic recovery
/// happens here; see CLAUDE.md rules 21-24).
/// No gallery saving or dual recording happens here.
actor RecordingService {
    private(set) var state: RecordingState = .idle
    private(set) var lastError: RecordingError?
    private(set) var lastValidationResult: RecordingValidationResult?
    private(set) var lastImportedRecord: VideoRecord?
    /// True while recording is paused due to an interruption. `state` deliberately
    /// stays `.recording` while paused — pausing is a temporary, resumable condition,
    /// not a terminal one, and the existing Stop button must keep working regardless.
    private(set) var isPaused = false

    private let validator = RecordingValidator()
    private let libraryService: InternalVideoLibraryService
    /// `nonisolated` because these are just references to other actors — safe to hand
    /// out (actors are inherently `Sendable`) without crossing this actor's isolation.
    nonisolated let performanceMonitor = RecordingPerformanceMonitor()
    nonisolated let checkpointStore = RecordingCheckpointStore()

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var isSessionStarted = false
    private var activeQuality: RecordingQuality = .fullHD
    private var activeFPS: RecordingFPS = .fps30
    private var lastAppendedTimestamp: CMTime = .zero
    private var recordingStartTime: Date?
    private var checkpointTask: Task<Void, Never>?

    init(libraryService: InternalVideoLibraryService) {
        self.libraryService = libraryService
    }

    /// Called by `CameraService` once it has resolved the actual capture resolution
    /// and frame rate (which may differ from the user's raw preference if a fallback
    /// occurred), so the asset writer and recovery checkpoint always reflect what the
    /// session is really running at.
    func updateRecordingFormat(quality: RecordingQuality, fps: RecordingFPS) {
        activeQuality = quality
        activeFPS = fps
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

        // Warn-only check (requirement 13) — never blocks preparing or recording.
        await performanceMonitor.checkAvailableStorage()

        do {
            try setUpWriter()
        } catch {
            lastError = .writerCreationFailed
            state = .failed
        }
        return state
    }

    @discardableResult
    func startRecording() async -> RecordingState {
        guard state == .preparing, assetWriter != nil else { return state }
        state = .recording
        isPaused = false
        recordingStartTime = Date()
        await performanceMonitor.startMonitoring()
        await saveCheckpoint()
        startCheckpointing()
        return state
    }

    /// Stops accepting new sample buffers without finishing the file, so whatever was
    /// captured before the interruption stays intact and a future resume feature could
    /// continue writing to the same session. Preserves a checkpoint immediately
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
        await append(sampleBuffer, to: videoInput)
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        await append(sampleBuffer, to: audioInput)
    }

    /// Finishes writing and validates the resulting file.
    /// `expectsAudioTrack` should reflect whether microphone permission was granted —
    /// a missing audio track is only an error when audio was actually expected.
    @discardableResult
    func stopRecording(expectsAudioTrack: Bool) async -> RecordingState {
        guard state == .recording else { return state }
        state = .stopping
        stopCheckpointing()
        await performanceMonitor.stopMonitoring()

        guard let writer = assetWriter, isSessionStarted, let url = outputURL else {
            // Nothing was ever written (e.g. stopped before the first sample buffer arrived).
            // Requirement 8: keep the checkpoint — this counts as an unexpected failure.
            lastError = .writeFailed
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

        guard writer.status == .completed else {
            lastError = .writeFailed
            state = .failed
            return state
        }

        let result = await validator.validate(fileURL: url, expectsAudioTrack: expectsAudioTrack)
        lastValidationResult = result

        guard result.isValid else {
            lastError = result.error ?? .validationFailed
            state = .failed
            return state
        }

        do {
            // Moves the file out of the temporary directory — nothing stays there once
            // a recording succeeds.
            lastImportedRecord = try await libraryService.importRecording(from: url, validation: result)
            state = .finished
            // Requirement 7: only a successful completion clears the checkpoint.
            await checkpointStore.delete()
        } catch {
            lastError = .unknown
            state = .failed
        }
        return state
    }

    /// The finished recording's permanent file URL in the internal library, if the last
    /// recording completed, validated, and was imported successfully.
    func outputFileURL() -> URL? {
        lastImportedRecord?.localURL
    }

    private func setUpWriter() throws {
        let url = Self.makeOutputURL()
        let writer = try AVAssetWriter(url: url, fileType: .mov)

        let dimensions = activeQuality.dimensions
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height
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

        assetWriter = writer
        videoInput = videoWriterInput
        audioInput = audioWriterInput
        outputURL = url
        isSessionStarted = false
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) async {
        // Paused means an interruption is in effect — never write new samples while
        // paused (requirement 5: never corrupt the existing recording).
        guard state == .recording, !isPaused, let writer = assetWriter, let input else { return }

        if !isSessionStarted {
            guard writer.startWriting() else {
                lastError = .writeFailed
                state = .failed
                return
            }
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: startTime)
            isSessionStarted = true
        }

        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }

        let writeStart = Date()
        input.append(sampleBuffer)
        await performanceMonitor.recordWriteLatency(Date().timeIntervalSince(writeStart))
        lastAppendedTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if writer.status == .failed {
            lastError = .writeFailed
            state = .failed
        }
    }

    private static func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
    }

    // MARK: - Checkpoint persistence (requirements 2-8; recovery itself is not implemented)

    /// Builds the current checkpoint from in-memory state. `nil` before a recording has
    /// actually started (nothing worth persisting yet).
    func currentCheckpoint() -> RecordingCheckpoint? {
        guard let url = outputURL, let startTime = recordingStartTime else { return nil }
        return RecordingCheckpoint(
            recordingState: state,
            outputURL: url,
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
