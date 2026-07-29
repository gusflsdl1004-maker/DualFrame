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
        /// Task 047: how many video frames this writer actually accepted, and how many
        /// were skipped because its input wasn't ready. Short-form was failing with no
        /// trace of why: its frames go through a synchronous 4K crop, so under load
        /// `isReadyForMoreMediaData` goes false and `append` silently `continue`d,
        /// leaving the writer to reach `finishWriting()` with an empty video track.
        /// Counting both makes that visible instead of surfacing as an opaque failure.
        var appendedVideoFrames = 0
        var skippedVideoFrames = 0
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
    /// Task 029: a more granular diagnosis of the most recent `.failed` transition than
    /// `lastError` alone provides — purely observational, read only by the debug panel.
    private(set) var lastStartupFailureReason: RecordingStartupFailureReason?
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
    /// Task 049: the single definition of the recording bitrate, shared with
    /// `RecordingCapacityViewModel`'s remaining-time estimate.
    private let bitrateService = BitrateEstimationService()
    private let libraryService: InternalVideoLibraryService
    /// `nonisolated` because these are just references to other actors — safe to hand
    /// out (actors are inherently `Sendable`) without crossing this actor's isolation.
    nonisolated let performanceMonitor = RecordingPerformanceMonitor()
    nonisolated let checkpointStore = RecordingCheckpointStore()
    /// Task 029: shared with `CameraService` (which reads it via its own
    /// `recordingService` reference) so "Camera Configured"/"Session Started" land in
    /// the same timeline as this actor's own stages — one ring buffer, not two.
    nonisolated let diagnosticsLogService = RecordingDiagnosticsLogService()
    /// Only ever invoked for the short-form output's video (see `append`) — never for
    /// long-form or `.single` mode.
    private let frameCropper = VideoFrameCropper()

    private var writerContexts: [OutputProfile: WriterContext] = [:]
    private(set) var activeQuality: RecordingQuality = .fullHD
    private(set) var activeFPS: RecordingFPS = .fps30
    /// Task 022: applied to every writer's video input at creation time (see
    /// `makeWriterContext`), identically across long-form/short-form/single — pure
    /// file-track metadata computed by `OrientationManager`, never by this actor
    /// (Additional Development Rule, Task 022).
    private var recordingTransform: CGAffineTransform = .identity
    private var lastAppendedTimestamp: CMTime = .zero
    private(set) var recordingStartTime: Date?
    private var checkpointTask: Task<Void, Never>?
    /// How many times a checkpoint was actually saved during the current/last
    /// recording — surfaced in the diagnostics report.
    private(set) var checkpointSaveCount = 0

    #if DEBUG
    /// Task 044: counters backing `logVideoSampleBufferStage(_:)` only — never read
    /// by any non-debug code path.
    private var debugVideoBufferCount = 0
    private var debugFirstBufferTime: CMTime?

    /// Task 048: per-writer timing, to locate the bottleneck rather than infer it.
    /// Kept in its own Debug-only dictionary rather than added to `WriterContext`, so
    /// the recording path carries no measurement state in Release at all.
    private struct ProfileTimingStats {
        var appendedFrames = 0
        /// Time inside `VideoFrameCropper.croppedPixelBuffer` (short-form only).
        var cropTotal: TimeInterval = 0
        var cropMax: TimeInterval = 0
        /// Time inside `AVAssetWriterInput.append`/`AVAssetWriterInputPixelBufferAdaptor.append`.
        var writeTotal: TimeInterval = 0
        var writeMax: TimeInterval = 0
        /// Frames this writer refused because `isReadyForMoreMediaData` was false —
        /// i.e. the writer made the pipeline wait.
        var notReadyCount = 0
        /// Longest stretch this writer went without accepting a frame.
        var lastAcceptedAt: Date?
        var maxStarvationGap: TimeInterval = 0
    }
    private var debugTimings: [OutputProfile: ProfileTimingStats] = [:]
    /// Wall-clock time `append(_:isVideo:)` occupied the actor, across all writers —
    /// the figure that matters for whether the actor itself is the bottleneck.
    private var debugActorHoldTotal: TimeInterval = 0
    private var debugActorHoldMax: TimeInterval = 0
    private var debugActorHoldSamples = 0
    #endif

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

    /// Stores the transform `CameraService`/`OrientationManager` computed for the next
    /// recording (Task 022 requirement 9: this actor only stores and applies a given
    /// value — it never computes orientation). Applied once per writer at creation time
    /// in `makeWriterContext`; changing it while a recording is already in progress has
    /// no effect on that recording (requirement 5/6 — orientation changes mid-recording
    /// never touch `RecordingState`, checkpoints, validation, or the writer already in use).
    func updateRecordingTransform(_ transform: CGAffineTransform) {
        recordingTransform = transform
    }

    /// Task 029 requirement 4: the only allowed `RecordingState` transitions. Anything
    /// else gets logged (never blocked — this task must not change actual behavior,
    /// only observe it) as a signal that something upstream did the wrong thing.
    private static let allowedStateTransitions: [RecordingState: Set<RecordingState>] = [
        .idle: [.preparing],
        .preparing: [.recording, .failed],
        .recording: [.stopping, .failed],
        .stopping: [.finished, .failed],
        .finished: [.preparing],
        .failed: [.preparing]
    ]

    /// Task 029 requirements 1/4: every `state` change goes through here instead of a
    /// bare assignment, so each one gets validated against
    /// `allowedStateTransitions` and logged to `diagnosticsLogService` — without
    /// changing what value ends up in `state` or when (the assignment happens exactly
    /// where it always did; this just wraps it).
    private func setState(_ newState: RecordingState, detail: String? = nil) {
        if state != newState, !(Self.allowedStateTransitions[state]?.contains(newState) ?? false) {
            logEvent("Invalid transition", detail: "\(state) -> \(newState)")
            lastStartupFailureReason = .invalidStateTransition
        }
        state = newState
        logEvent(Self.stageName(for: newState), detail: detail)
    }

    private static func stageName(for state: RecordingState) -> String {
        switch state {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .recording: "Recording"
        case .stopping: "Stopping"
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }

    /// Task 029 requirement 5: fire-and-forget on purpose — never `await`ed inline, so
    /// a slow or failing log write can never add latency to (or interrupt) the actual
    /// recording pipeline. `RecordingDiagnosticsLogService.log` cannot throw, so there
    /// is nothing to catch; this is simply never on the critical path at all.
    private func logEvent(_ stage: String, detail: String? = nil) {
        let logService = diagnosticsLogService
        Task { await logService.log(stage, detail: detail) }
    }

    @discardableResult
    func prepareRecording() async -> RecordingState {
        guard state == .idle || state == .finished || state == .failed else { return state }
        setState(.preparing)
        lastError = nil
        lastStartupFailureReason = nil
        lastValidationResult = nil
        lastImportedRecord = nil
        lastAppendedTimestamp = .zero
        recordingStartTime = nil
        isPaused = false
        checkpointSaveCount = 0
        #if DEBUG
        debugVideoBufferCount = 0
        debugFirstBufferTime = nil
        // Task 048: timings are per-recording, never carried across sessions.
        debugTimings = [:]
        debugActorHoldTotal = 0
        debugActorHoldMax = 0
        debugActorHoldSamples = 0
        #endif

        // Warn-only check (requirement 13) — never blocks preparing or recording.
        await performanceMonitor.checkAvailableStorage()

        setUpWriters()

        // Requirement 6/9: only fail overall if *every* target profile's writer could
        // not be created. In `.single` mode there is exactly one target profile, so
        // this reduces to the original single-writer failure behavior exactly.
        guard !writerContexts.isEmpty else {
            lastError = .writerCreationFailed
            lastStartupFailureReason = .writerCreationFailed
            setState(.failed)
            return state
        }
        logEvent("Writer Created", detail: "\(writerContexts.count) profile(s)")
        return state
    }

    @discardableResult
    func startRecording() async -> RecordingState {
        guard state == .preparing, !writerContexts.isEmpty else { return state }
        setState(.recording)
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

    /// Un-pauses a recording paused by `pauseRecording()`. Only ever called from
    /// `RecordingViewModel.resumeRecording()`, itself only invoked when the user taps
    /// the Resume button — never automatically (this task's requirement 1). `state`
    /// was already `.recording` throughout the pause (Task 017's design), and nothing
    /// about `sessionID`/`recordingStartTime`/`RecordingGroup` is touched here — this
    /// method's only job is to let `append(_:isVideo:)` start accepting samples again
    /// and to immediately re-save a checkpoint so recovery data reflects the resume
    /// (requirement 4).
    func resumeRecording() async {
        guard state == .recording, isPaused else { return }
        isPaused = false
        await saveCheckpoint()
    }

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        #if DEBUG
        logVideoSampleBufferStage(sampleBuffer)
        #endif
        await append(sampleBuffer, isVideo: true)
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        await append(sampleBuffer, isVideo: false)
    }

    #if DEBUG
    /// Task 048: records one write duration and the gap since this writer last
    /// accepted a frame (its starvation interval).
    private func recordDebugWrite(profile: OutputProfile, duration: TimeInterval) {
        var stats = debugTimings[profile] ?? ProfileTimingStats()
        stats.appendedFrames += 1
        stats.writeTotal += duration
        stats.writeMax = max(stats.writeMax, duration)
        let now = Date()
        if let last = stats.lastAcceptedAt {
            stats.maxStarvationGap = max(stats.maxStarvationGap, now.timeIntervalSince(last))
        }
        stats.lastAcceptedAt = now
        debugTimings[profile] = stats
    }

    /// Task 048: per-writer bottleneck breakdown. Printed periodically during the
    /// recording and once more at the end, so a long recording shows whether the cost
    /// is steady or degrades as the writers fall behind.
    ///
    /// How to read it: at 60fps the pipeline has 16.7ms per frame (33.3ms at 30fps),
    /// and because every writer is serviced on the same actor, `actorHold` is the
    /// figure that has to stay under that budget — not any individual writer's.
    /// `crop` vs `write` says which half of short-form's work dominates; `notReady`
    /// counts frames a writer refused outright.
    private func logTimingBreakdown(label: String) {
        let frameBudgetMs = 1000.0 / Double(activeFPS.rawValue)
        let avgHold = debugActorHoldSamples > 0 ? debugActorHoldTotal / Double(debugActorHoldSamples) * 1000 : 0
        print(String(
            format: "[Task048-Perf] %@ actorHold avg=%.2fms max=%.2fms budget=%.2fms samples=%d",
            label, avgHold, debugActorHoldMax * 1000, frameBudgetMs, debugActorHoldSamples
        ))

        for (profile, stats) in debugTimings.sorted(by: { $0.key.outputName < $1.key.outputName }) {
            let avgCrop = stats.appendedFrames > 0 ? stats.cropTotal / Double(stats.appendedFrames) * 1000 : 0
            let avgWrite = stats.appendedFrames > 0 ? stats.writeTotal / Double(stats.appendedFrames) * 1000 : 0
            print(String(
                format: "[Task048-Perf] %@ %@ frames=%d crop avg=%.2fms max=%.2fms | write avg=%.2fms max=%.2fms | notReady=%d maxGap=%.0fms",
                label, profile.outputName, stats.appendedFrames,
                avgCrop, stats.cropMax * 1000,
                avgWrite, stats.writeMax * 1000,
                stats.notReadyCount, stats.maxStarvationGap * 1000
            ))
        }
    }

    /// Task 044 requirement 1/2/4: the final "File" stage — reads the just-written
    /// file's own track metadata, so the saved resolution and nominal frame rate can
    /// be compared against every earlier stage without leaving the app or running
    /// ffprobe by hand. This is the value that must read 3840x2160 / 60fps for the
    /// bug to be considered fixed.
    private func logFinishedFileStage(profile: OutputProfile, url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let nominalFrameRate = try? await track.load(.nominalFrameRate),
              let transform = try? await track.load(.preferredTransform) else {
            print("[Task044-Debug] STAGE 7 FILE     profile=\(profile.outputName) — could not read video track metadata")
            return
        }
        // naturalSize is pre-transform; a portrait recording carries its rotation in
        // preferredTransform, so the visually-presented size is reported too.
        let presentedSize = naturalSize.applying(transform)
        print("[Task044-Debug] STAGE 7 FILE     profile=\(profile.outputName) naturalSize=\(Int(naturalSize.width))x\(Int(naturalSize.height)) presentedSize=\(Int(abs(presentedSize.width)))x\(Int(abs(presentedSize.height))) nominalFrameRate=\(String(format: "%.2f", nominalFrameRate))fps url=\(url.lastPathComponent)")

        // Task 051 requirement 3: the bitrate the file *actually* came out at, next to
        // the one the writer was configured with. This is the measurement that settles
        // "is AVVideoAverageBitRateKey actually being applied?" — if `configured` moves
        // with the quality preset but `actualVideoTrack` does not, the encoder is
        // ignoring the setting; if both move but the picture still looks the same, the
        // bitrate is applied and the calculation itself needs tuning instead.
        let format = effectiveWriterFormat(for: profile)
        let configured = bitrateService.videoBitrate(
            width: format.resolution.width,
            height: format.resolution.height,
            fps: format.fps
        )
        // `estimatedDataRate` is the track's own measured average, independent of the
        // container overhead that a file-size calculation would fold in.
        let actualTrackRate = (try? await track.load(.estimatedDataRate)).map(Double.init) ?? 0
        let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let wholeFileRate = duration > 0 ? Double(fileBytes) * 8 / duration : 0

        print(String(
            format: "[Task051-Bitrate] profile=%@ preset=%@ configured=%.1fMbps actualVideoTrack=%.1fMbps wholeFile=%.1fMbps ratio=%.2f duration=%.1fs size=%.1fMB",
            profile.outputName,
            bitrateService.currentPreset.title,
            Double(configured) / 1_000_000,
            actualTrackRate / 1_000_000,
            wholeFileRate / 1_000_000,
            configured > 0 ? actualTrackRate / Double(configured) : 0,
            duration,
            Double(fileBytes) / 1_000_000
        ))
    }

    /// Task 044 requirement 1/2: the "SampleBuffer" stage of the requested trace —
    /// the one link that was never instrumented, and the only place that can prove
    /// whether the buffers actually arriving are the size/rate the device claims.
    ///
    /// Logs the first buffer of each recording (its real dimensions, both from the
    /// format description and the backing `CVPixelBuffer`), then every 120th buffer
    /// with the measured arrival rate — deliberately not every frame, which at 60fps
    /// would flood the console badly enough to distort the timing being measured.
    private func logVideoSampleBufferStage(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        debugVideoBufferCount += 1

        let formatDimensions = CMSampleBufferGetFormatDescription(sampleBuffer)
            .map { CMVideoFormatDescriptionGetDimensions($0) }
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let pixelWidth = pixelBuffer.map { CVPixelBufferGetWidth($0) } ?? -1
        let pixelHeight = pixelBuffer.map { CVPixelBufferGetHeight($0) } ?? -1

        if debugVideoBufferCount == 1 {
            debugFirstBufferTime = presentationTime
            print("[Task044-Debug] STAGE 5 BUFFER#1  CMSampleBuffer=\(formatDimensions.map { "\($0.width)x\($0.height)" } ?? "nil") CVPixelBuffer=\(pixelWidth)x\(pixelHeight) writerExpects=\(activeQuality.dimensions.width)x\(activeQuality.dimensions.height) @\(activeFPS.rawValue)fps")
            return
        }

        guard debugVideoBufferCount % 120 == 0,
              let firstTime = debugFirstBufferTime else { return }
        let elapsed = presentationTime.seconds - firstTime.seconds
        guard elapsed > 0 else { return }
        let measuredFPS = Double(debugVideoBufferCount - 1) / elapsed
        print("[Task044-Debug] STAGE 5 BUFFER#\(debugVideoBufferCount) measuredArrivalFPS=\(String(format: "%.2f", measuredFPS)) over \(String(format: "%.1f", elapsed))s CMSampleBuffer=\(formatDimensions.map { "\($0.width)x\($0.height)" } ?? "nil") CVPixelBuffer=\(pixelWidth)x\(pixelHeight)")
        // Task 048: printed on the same cadence as the arrival-rate sample, so the
        // measured FPS and the cost breakdown that explains it sit together.
        logTimingBreakdown(label: "@\(debugVideoBufferCount)")
    }
    #endif

    /// Finishes writing and validates each active writer's file independently
    /// (requirement 7) — a failure in one never skips or cancels another.
    /// `expectsAudioTrack` should reflect whether microphone permission was granted —
    /// a missing audio track is only an error when audio was actually expected.
    @discardableResult
    func stopRecording(expectsAudioTrack: Bool) async -> RecordingState {
        guard state == .recording else { return state }
        setState(.stopping)
        stopCheckpointing()
        await performanceMonitor.stopMonitoring()

        #if DEBUG
        // Task 048: the whole-recording totals, printed before any writer is finished
        // so the numbers describe the recording itself rather than teardown.
        logTimingBreakdown(label: "FINAL")
        #endif

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
                // Task 029: only diagnose "never started" here if this writer wasn't
                // already marked failed elsewhere (which already recorded its own,
                // more specific reason via `markWriterFailed`).
                if !context.hasFailed {
                    lastStartupFailureReason = .sessionNotPrepared
                    logEvent("Writer never started", detail: profile.outputName)
                }
                // Task 036: this writer will never reach `finishWriting()` below —
                // explicitly cancel it here instead of leaving it dangling in
                // `writerContexts` until the next `prepareRecording()` overwrites it.
                cancelWriterIfNeeded(context.writer, isSessionStarted: context.isSessionStarted)
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
                lastStartupFailureReason = .finishWritingFailed
                // Task 047: `writer.error` was never read anywhere, which is why the
                // short-form failure had no diagnosable cause — the status said
                // "failed" and the actual reason was thrown away. Recorded alongside
                // the frame counts, which distinguish "the writer rejected the data"
                // from "the writer never received any data".
                let reason = context.writer.error.map { "\($0)" } ?? "unknown"
                logEvent(
                    "finishWriting failed",
                    detail: "\(profile.outputName): appended=\(context.appendedVideoFrames) skipped=\(context.skippedVideoFrames) error=\(reason)"
                )
                #if DEBUG
                print("[Task044-Debug] STAGE 7 FAIL     profile=\(profile.outputName) writerStatus=\(context.writer.status.rawValue) appendedVideoFrames=\(context.appendedVideoFrames) skippedVideoFrames=\(context.skippedVideoFrames) writer.error=\(reason)")
                #endif
                continue
            }

            // Requirement 7: validated independently per profile.
            let result = await validator.validate(fileURL: context.outputURL, expectsAudioTrack: expectsAudioTrack)
            writerStatuses[profile]?.validationResult = result
            lastValidationResult = result

            #if DEBUG
            print("[Task044-Debug] STAGE 6b FRAMES  profile=\(profile.outputName) appendedVideoFrames=\(context.appendedVideoFrames) skippedVideoFrames=\(context.skippedVideoFrames)")
            await logFinishedFileStage(profile: profile, url: context.outputURL)
            #endif

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
                lastStartupFailureReason = .unknown
                logEvent("Import failed", detail: profile.outputName)
            }
        }

        if anySucceeded {
            setState(.finished)
            // Requirement 7 (Task 018): only a successful completion clears the
            // checkpoint. In dual mode this fires as long as at least one output
            // succeeded — rule 1: never lose recorded video just because its sibling
            // output failed.
            await checkpointStore.delete()
        } else {
            setState(.failed)
        }
        // Task 036: every writer this recording attempt used has now either finished
        // (finishWriting already called above), or been cancelled (in the guard branch
        // above). Nothing should still hold an AVAssetWriter/AVAssetWriterInput/
        // PixelBufferAdaptor reference past this point — release them immediately
        // rather than waiting for the next prepareRecording() to overwrite
        // writerContexts. writerStatuses is untouched — the UI still needs to show
        // this recording's final per-profile result.
        writerContexts.removeAll()
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
    /// `.single` yields one ad-hoc profile built from the user's `activeQuality`/
    /// `activeFPS`; `.dual` yields the two canonical constants.
    ///
    /// Task 046: `.dual` deliberately still returns the *unmodified* `.longForm`/
    /// `.shortForm` constants, because these values are load-bearing **identities**,
    /// not just data — they key `writerContexts`/`writerStatuses`, they select the
    /// crop path (`profile == .shortForm` in `makeWriterContext`), and
    /// `RecordingViewModel` looks up `statuses[.longForm]`/`statuses[.shortForm]` for
    /// both the dual status rows and `RecordingGroup` membership. Rebuilding them with
    /// different resolution/fps would change their `Equatable` identity and silently
    /// break every one of those lookups (short-form would stop being cropped).
    ///
    /// The resolution/frame rate a writer is actually built with is therefore resolved
    /// separately, in `effectiveWriterFormat(for:)`.
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

    /// Task 046: the resolution and frame rate a writer for `profile` is actually
    /// created with — **the fix for "4K/60 selected, 1080p/30 recorded" in `.dual`
    /// mode.**
    ///
    /// Root cause: `OutputProfile.longForm` is a hardcoded constant
    /// (1920x1080 @ .fps30). In `.dual` mode `targetProfiles` returned that constant
    /// and `makeWriterContext` read `profile.resolution`/`profile.fps` straight from
    /// it, so the user's quality/FPS choice was discarded entirely — the capture
    /// device was correctly running at 3840x2160 (confirmed by STAGE 5's sample
    /// buffers) while the writer was unconditionally built for 1080p30. `.single`
    /// mode never had this bug because `singleModeProfile()` already derived its
    /// values from `activeQuality`/`activeFPS`.
    ///
    /// Long-form (and single) now follow `activeQuality`/`activeFPS`, so the writer
    /// matches what the camera is actually delivering.
    ///
    /// Short-form deliberately keeps its fixed 1080x1920 vertical delivery size: it is
    /// produced by centre-cropping the 16:9 source, so at 4K the crop is only ~1215
    /// points wide — targeting 2160x3840 would upscale, costing storage and encode
    /// time for no real detail. Its frame rate *does* follow `activeFPS` so both
    /// outputs of one session share timing (CLAUDE.md rule 41).
    private func effectiveWriterFormat(for profile: OutputProfile) -> (resolution: OutputResolution, fps: RecordingFPS) {
        if profile == .shortForm {
            return (OutputProfile.shortForm.resolution, activeFPS)
        }
        let dimensions = activeQuality.dimensions
        return (OutputResolution(width: dimensions.width, height: dimensions.height), activeFPS)
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

        // Task 046: resolved from `activeQuality`/`activeFPS` rather than read off
        // `profile`, whose `.longForm`/`.shortForm` constants are hardcoded 1080p30.
        // See `effectiveWriterFormat(for:)`.
        let format = effectiveWriterFormat(for: profile)

        // Task 049 requirement 2: an explicit bitrate. With no
        // `AVVideoAverageBitRateKey` the H.264 encoder picked its own default, which at
        // 4K is well below what the resolution needs — the reported quality loss. The
        // value comes from `BitrateEstimationService`, the same source
        // `RecordingCapacityViewModel` uses for "예상 촬영 가능", so the encoder and the
        // remaining-time estimate can no longer disagree.
        let averageBitrate = bitrateService.videoBitrate(
            width: format.resolution.width,
            height: format.resolution.height,
            fps: format.fps
        )
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: format.resolution.width,
            AVVideoHeightKey: format.resolution.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitrate,
                // Task 044 requirement 1: tells the encoder what source rate to expect.
                // Without it the H.264 encoder assumes a default (30fps) when choosing
                // keyframe placement and rate control, which can end up reflected in
                // the written file's nominal frame rate even when 60fps of buffers
                // arrive.
                AVVideoExpectedSourceFrameRateKey: format.fps.rawValue,
                // One keyframe per second: standard for real-time capture, and it
                // bounds how much is lost if a file is truncated by a crash.
                AVVideoMaxKeyFrameIntervalDurationKey: 1
            ]
        ]
        #if DEBUG
        // Task 044 requirement 1/2: the "Writer" stage — printed from the exact
        // dictionary handed to AVAssetWriterInput, not re-derived from activeQuality,
        // so this is literally what the writer was configured with.
        //
        // Task 046: `profileConstant` shows the hardcoded value the writer used to be
        // built from, next to what it is now actually built with — so the next
        // real-device log makes the fix unambiguous. In `.dual` mode this line prints
        // twice: Long-form (expected 3840x2160 at 4K) and Short-form (intentionally
        // 1080x1920 — a vertical crop target, not a downscale bug).
        print("[Task044-Debug] STAGE 6 WRITER   profile=\(profile.outputName) AVVideoWidthKey=\(format.resolution.width) AVVideoHeightKey=\(format.resolution.height) AVVideoExpectedSourceFrameRateKey=\(format.fps.rawValue) AVVideoAverageBitRateKey=\(averageBitrate) (\(String(format: "%.1f", Double(averageBitrate) / 1_000_000))Mbps) | RecordingService.activeQuality=\(activeQuality.title) RecordingService.activeFPS=\(activeFPS.rawValue) | profileConstant=\(profile.resolution.width)x\(profile.resolution.height)@\(profile.fps.rawValue)")
        #endif
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = true
        // Task 022 requirement 7: applied identically to every profile — long-form,
        // short-form, and single all get the same transform, set once here and never
        // touched again by this actor.
        videoWriterInput.transform = recordingTransform

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
            // Task 046: uses the same resolved `format` the writer input above was
            // built with, so the crop target and the encoder can never disagree.
            // (For short-form these are still 1080x1920 — see `effectiveWriterFormat`.)
            let targetSize = CGSize(width: format.resolution.width, height: format.resolution.height)
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

        #if DEBUG
        // Task 048: measures how long this call occupies the actor. Every writer's
        // work is serialized here, so if this exceeds the frame interval (16.7ms at
        // 60fps, 33.3ms at 30fps) the actor itself is the bottleneck, regardless of
        // how fast any individual writer is.
        let actorHoldStart = isVideo ? Date() : nil
        defer {
            if let actorHoldStart {
                let held = Date().timeIntervalSince(actorHoldStart)
                debugActorHoldTotal += held
                debugActorHoldMax = max(debugActorHoldMax, held)
                debugActorHoldSamples += 1
            }
        }
        #endif

        for profile in writerContexts.keys {
            guard var context = writerContexts[profile], !context.hasFailed else { continue }
            let writer = context.writer
            let input = isVideo ? context.videoInput : context.audioInput

            if !context.isSessionStarted {
                guard writer.startWriting() else {
                    markWriterFailed(profile, error: .writeFailed, startupReason: .sessionNotPrepared)
                    continue
                }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                context.isSessionStarted = true
                writerContexts[profile] = context
            }

            guard writer.status == .writing, input.isReadyForMoreMediaData else {
                // Task 047: this `continue` used to be completely silent. For
                // short-form under a 4K load it is the common path — its frames go
                // through a synchronous crop, so its input falls behind and every
                // skipped frame vanished without a trace, leaving `finishWriting()` to
                // fail opaquely on an empty video track. Now counted per writer and
                // surfaced in `stopRecording`.
                if isVideo {
                    writerContexts[profile]?.skippedVideoFrames += 1
                    #if DEBUG
                    // Task 048: "Writer 대기 시간" — this writer refused the frame
                    // because it hadn't finished the previous one.
                    debugTimings[profile, default: ProfileTimingStats()].notReadyCount += 1
                    #endif
                }
                continue
            }

            let writeStart = Date()
            if isVideo, let cropConfiguration = context.cropConfiguration, let adaptor = context.pixelBufferAdaptor {
                // Task 021: the only path that differs from pre-Task-021 behavior — used
                // exclusively for the short-form output's video. `nil` from the cropper
                // means this single frame gets dropped, not that the writer failed; only
                // an actual `adaptor.append` rejection counts as a writer-level failure.
                if let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    // Task 048: crop timed on its own, separately from the append that
                    // follows — the whole point is to tell those two apart.
                    #if DEBUG
                    let cropStart = Date()
                    #endif
                    let croppedBuffer = frameCropper.croppedPixelBuffer(from: sourcePixelBuffer, configuration: cropConfiguration)
                    #if DEBUG
                    let cropDuration = Date().timeIntervalSince(cropStart)
                    debugTimings[profile, default: ProfileTimingStats()].cropTotal += cropDuration
                    debugTimings[profile, default: ProfileTimingStats()].cropMax = max(
                        debugTimings[profile, default: ProfileTimingStats()].cropMax,
                        cropDuration
                    )
                    #endif

                    if let croppedBuffer {
                        #if DEBUG
                        let adaptorStart = Date()
                        #endif
                        let appended = adaptor.append(croppedBuffer, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                        #if DEBUG
                        recordDebugWrite(profile: profile, duration: Date().timeIntervalSince(adaptorStart))
                        #endif
                        if appended {
                            writerContexts[profile]?.appendedVideoFrames += 1
                        } else {
                            markWriterFailed(profile, error: .writeFailed, startupReason: .appendFailed)
                        }
                    } else {
                        // Cropper returned nil — one dropped frame, not a writer failure
                        // (unchanged), but no longer invisible.
                        writerContexts[profile]?.skippedVideoFrames += 1
                    }
                } else {
                    writerContexts[profile]?.skippedVideoFrames += 1
                }
            } else {
                // Unchanged since before Task 021: long-form, `.single` mode, and every
                // audio append always take this exact path.
                #if DEBUG
                let inputStart = Date()
                #endif
                input.append(sampleBuffer)
                if isVideo {
                    // Counted in every configuration, not just Debug — `stopRecording`
                    // reports it as part of the non-Debug failure diagnostics.
                    writerContexts[profile]?.appendedVideoFrames += 1
                    #if DEBUG
                    recordDebugWrite(profile: profile, duration: Date().timeIntervalSince(inputStart))
                    #endif
                }
            }
            await performanceMonitor.recordWriteLatency(Date().timeIntervalSince(writeStart))
            lastAppendedTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if writer.status == .failed {
                markWriterFailed(profile, error: .writeFailed, startupReason: .appendFailed)
            }
        }

        // Requirement 6's boundary: only when literally every active writer has failed
        // does the overall session stop — a single writer failing must never affect the
        // others (or, in `.single` mode with its one writer, this reduces to the
        // original "any failure stops the recording" behavior).
        if !writerContexts.isEmpty, writerContexts.values.allSatisfy(\.hasFailed) {
            lastError = .writeFailed
            // Task 036: `state` is about to leave `.recording` here, which means
            // `stopRecording()`'s own `guard state == .recording` will reject any later
            // call — this is the only point these writers will ever be released from.
            // Without this, every writer that failed mid-recording (which, in `.single`
            // mode, is every failure at all, since one writer failing already satisfies
            // `allSatisfy`) would stay referenced in `writerContexts` — uncancelled and
            // unreleased — until the next `prepareRecording()` overwrote the dictionary.
            for context in writerContexts.values {
                cancelWriterIfNeeded(context.writer, isSessionStarted: context.isSessionStarted)
            }
            writerContexts.removeAll()
            // Task 036: `stopRecording()` normally stops these two — since it will
            // never run for this path either, stop them here so the checkpoint timer
            // and performance monitor don't keep polling indefinitely after the
            // recording has already ended.
            stopCheckpointing()
            await performanceMonitor.stopMonitoring()
            setState(.failed)
        }
    }

    /// Task 029 requirement 2: `startupReason` is purely additive diagnostic detail —
    /// `error`/`writerStatuses` behave exactly as before this task.
    private func markWriterFailed(_ profile: OutputProfile, error: RecordingError, startupReason: RecordingStartupFailureReason) {
        writerContexts[profile]?.hasFailed = true
        writerStatuses[profile]?.state = .failed
        writerStatuses[profile]?.lastError = error
        lastStartupFailureReason = startupReason
        logEvent("Writer failed", detail: "\(profile.outputName): \(startupReason.description)")
    }

    /// Task 036: cancels `writer` only if `startWriting()` actually succeeded for it at
    /// some point (`isSessionStarted`) — `AVAssetWriter.cancelWriting()` must never be
    /// called before `startWriting()` has succeeded, and never called twice on the same
    /// writer. A writer whose `startWriting()` itself failed, or that never received a
    /// single sample buffer, has nothing to cancel; dropping the last strong reference
    /// to it (via `writerContexts.removeAll()`) is enough to release it through ARC.
    private func cancelWriterIfNeeded(_ writer: AVAssetWriter, isSessionStarted: Bool) {
        guard isSessionStarted else { return }
        writer.cancelWriting()
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
    ///
    /// Task 034: captures `self` weakly, matching `RecordingPerformanceMonitor
    /// .startMonitoring()`'s existing pattern — the actor's own stored `checkpointTask`
    /// would otherwise hold a strong reference to a closure that holds a strong
    /// reference back to the actor, a cycle `deinit` can't break on its own (it never
    /// runs while the cycle exists).
    private func startCheckpointing() {
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self.saveCheckpoint()
            }
        }
    }

    private func stopCheckpointing() {
        checkpointTask?.cancel()
        checkpointTask = nil
    }
}
