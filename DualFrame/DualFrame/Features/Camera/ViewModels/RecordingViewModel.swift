//
//  RecordingViewModel.swift
//  DualFrame
//

import Combine
import CoreGraphics
import Foundation

/// Exposes recording state and validation results to the camera screen, and drives
/// the start/stop flow. Owns no capture/writing logic itself — that lives in
/// `RecordingService`.
@MainActor
final class RecordingViewModel: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastValidationResult: RecordingValidationResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var performanceSnapshot: RecordingPerformanceSnapshot?
    @Published private(set) var lowStorageWarning: String?
    @Published private(set) var interruptionStatus: InterruptionStatus = .none
    /// Non-nil only while `RecordingMode` is `.dual` and a recording has been prepared
    /// at least once — `nil` hides the corresponding UI row entirely (requirement 8).
    @Published private(set) var longFormStatusText: String?
    @Published private(set) var shortFormStatusText: String?
    /// Task 026: exposed for the debug-only verification view — non-nil for exactly
    /// the lifetime of `currentSessionMetadata` below.
    @Published private(set) var currentSessionID: UUID?

    /// Task 038 requirement 3: READY→준비 완료, RECORDING→녹화 중, FAILED→녹화 실패, etc.
    var statusText: String {
        switch state {
        case .idle: AppStrings.RecordingStatus.ready
        case .preparing: AppStrings.RecordingStatus.preparing
        case .recording: AppStrings.RecordingStatus.recording
        case .stopping: AppStrings.RecordingStatus.stopping
        case .finished: AppStrings.RecordingStatus.success
        case .failed: AppStrings.RecordingStatus.failed
        }
    }

    /// `state` alone stays `.recording` throughout a pause (Task 017's design) — this
    /// combines it with `interruptionStatus` so the UI can clearly distinguish
    /// Recording / Paused / Resume-available (requirement 5), without changing what
    /// `statusText`/`state` themselves mean anywhere else.
    var displayStatusText: String {
        guard state == .recording, interruptionStatus != .none else { return statusText }
        return AppStrings.RecordingStatus.paused
    }

    /// Task 045 requirement 4: `displayStatusText` only when it actually tells the user
    /// something — `nil` in the idle "준비 완료" state, which on a live camera preview
    /// is pure noise (the viewfinder being visible already says the camera is ready,
    /// and Apple's own Camera app shows nothing here). Every other state — preparing,
    /// recording, paused, stopping, finished, failed — is a real event worth a badge.
    ///
    /// `statusText`/`displayStatusText` themselves are unchanged, so the Debug panels
    /// and diagnostics that read them still see the full state including `.idle`.
    var visibleStatusText: String? {
        state == .idle ? nil : displayStatusText
    }

    var formattedDuration: String { Self.format(seconds: duration) }

    var formattedFileSize: String {
        guard let bytes = lastValidationResult?.fileSize else { return "--" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var formattedRecordedDuration: String {
        guard let seconds = lastValidationResult?.duration else { return "--" }
        return Self.format(seconds: seconds)
    }

    var formattedResolution: String {
        guard let size = lastValidationResult?.resolution else { return "--" }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    var isRecording: Bool { state == .recording }

    var formattedDroppedFrames: String {
        guard let snapshot = performanceSnapshot else { return "0" }
        return "\(snapshot.droppedVideoFrames + snapshot.droppedAudioBuffers)"
    }

    var memoryStatusText: String {
        guard let snapshot = performanceSnapshot else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(snapshot.memoryUsageBytes), countStyle: .memory)
    }

    var writeStatusText: String {
        guard let snapshot = performanceSnapshot else { return "--" }
        return snapshot.averageWriteLatency > 0.05 ? "Slow" : "Normal"
    }

    private let service: RecordingService
    private let diagnosticsService: RecordingDiagnosticsService
    private let dualRecordingCoordinator: DualRecordingCoordinator
    /// Task 022: used only to trigger `CameraService.refreshRecordingOrientation()`
    /// right before each recording starts — this view model never reads or computes
    /// orientation itself.
    private let cameraService: CameraService
    /// Task 023: used only to look up which `VideoRecord`s the session that just
    /// finished actually produced, so `recordGroup(startTime:endTime:)` can reference
    /// them by id — never to duplicate or reinterpret their data.
    private let libraryService: InternalVideoLibraryService
    private let groupService: RecordingGroupService
    /// Task 063 item 4: read only when writing diagnostics, to label the measurement
    /// with the capture setting it was taken under. Never used to change behaviour —
    /// `CameraService` is the only thing that acts on this setting.
    private let lateFrameHandlingSettingsService: LateFrameHandlingSettingsService
    /// Task 064: same role — read only when writing diagnostics, to label the
    /// measurement with the encoder condition it was taken under. `RecordingService` is
    /// the only thing that acts on these.
    private let encoderSettingsService = VideoEncoderSettingsService()
    private let bitratePresetSettingsService = BitratePresetSettingsService()
    /// Task 070: generation is handed to this and never awaited. Weak because it is
    /// owned by the app root and outlives this view model by design — a strong reference
    /// here would invert that ownership.
    weak var shortGenerationCoordinator: ShortGenerationCoordinator?
    private var durationTask: Task<Void, Never>?
    private var interruptionOccurredThisSession = false
    /// Task 024: created once per recording in `startRecording()`, cleared once
    /// `recordGroup()` has used it in `stopRecording()`. The single source of the
    /// `sessionID` every output of this recording shares.
    private var currentSessionMetadata: RecordingSessionMetadata?

    init(
        service: RecordingService,
        dualRecordingCoordinator: DualRecordingCoordinator,
        cameraService: CameraService,
        libraryService: InternalVideoLibraryService,
        diagnosticsService: RecordingDiagnosticsService = RecordingDiagnosticsService(),
        groupService: RecordingGroupService = RecordingGroupService(),
        lateFrameHandlingSettingsService: LateFrameHandlingSettingsService = LateFrameHandlingSettingsService()
    ) {
        self.service = service
        self.dualRecordingCoordinator = dualRecordingCoordinator
        self.cameraService = cameraService
        self.libraryService = libraryService
        self.diagnosticsService = diagnosticsService
        self.groupService = groupService
        self.lateFrameHandlingSettingsService = lateFrameHandlingSettingsService
    }

    /// Toggles between starting and stopping — the single button the camera screen exposes.
    /// `expectsAudioTrack` should reflect whether microphone permission was granted.
    func toggleRecording(expectsAudioTrack: Bool) {
        Task {
            if isRecording {
                await stopRecording(expectsAudioTrack: expectsAudioTrack)
            } else {
                await startRecording()
            }
        }
    }

    func startRecording() async {
        lastValidationResult = nil
        errorMessage = nil
        longFormStatusText = nil
        shortFormStatusText = nil

        if state != .preparing {
            // Requirement 1: read the user's current Settings choice fresh on every
            // start, not just once at app launch, and hand it to both the coordinator
            // (kept in sync per Task 018's design) and the service that actually acts
            // on it.
            let mode = RecordingModeSettingsService().load().mode
            await dualRecordingCoordinator.setMode(mode)
            await service.configureMode(mode)
            // Task 022 requirement 5: read fresh right before this recording, not once
            // at camera setup — a rotation *during* the recording that follows is never
            // read again, so it has no effect on the file already being written.
            await cameraService.refreshRecordingOrientation()
            // Task 043 requirement 1: same reasoning, for quality/FPS — a Settings
            // change made after the camera was first configured must be picked up
            // before this recording's writer is built, not left stale until app
            // restart (the real-device "4K selected, Full HD recorded" bug).
            await cameraService.refreshRecordingFormat()

            // Task 024 requirement 2: created exactly once per recording, before it
            // starts — every output this recording produces will be tagged with this
            // sessionID by `InternalVideoLibraryService`, without `RecordingService`
            // ever needing to know sessions exist.
            // Task 042: outputMode captured here too, same reasoning — a settings
            // change mid-recording must never retroactively relabel this session's
            // RecordingGroup.
            let metadata = RecordingSessionMetadata(
                sessionID: UUID(),
                startedAt: Date(),
                recordingMode: mode,
                selectedQuality: await service.activeQuality,
                selectedFPS: await service.activeFPS,
                outputMode: RecordingOutputModeSettingsService().load().outputMode
            )
            currentSessionMetadata = metadata
            currentSessionID = metadata.sessionID
            await libraryService.beginSession(metadata)

            state = await service.prepareRecording()
            lowStorageWarning = await service.performanceMonitor.lowStorageWarning

            if state != .preparing {
                // Task 025 requirement 2: `prepareRecording()` failed (e.g. writer
                // creation failed) — this session never reached `.recording`, so it
                // must not linger in `InternalVideoLibraryService.pendingSessions`.
                await endCurrentSession()
            }
        }
        guard state == .preparing else {
            errorMessage = await service.lastError?.message
            return
        }
        state = await service.startRecording()
        if state == .recording {
            performanceSnapshot = nil
            interruptionOccurredThisSession = false
            await refreshDualStatuses()
            startDurationTimer()
        } else {
            // Task 025 requirement 2: guards the (currently theoretical, since
            // `prepareRecording()` already succeeded) case where
            // `service.startRecording()` itself doesn't transition to `.recording`.
            await endCurrentSession()
        }
    }

    func stopRecording(expectsAudioTrack: Bool) async {
        guard state == .recording else {
            // Task 025 requirement 2: covers the user cancelling before the recording
            // ever reached `.recording` (e.g. tapping Stop while still `.preparing`) —
            // `startRecording()` already registered the session, so this view model is
            // responsible for cleaning it up if recording never truly began. A no-op
            // when nothing is pending (e.g. `state == .idle`).
            await endCurrentSession()
            return
        }
        let startTime = await service.recordingStartTime ?? Date()

        state = await service.stopRecording(expectsAudioTrack: expectsAudioTrack)
        stopDurationTimer()
        lastValidationResult = await service.lastValidationResult
        await refreshDualStatuses()

        let endTime = Date()
        // Captured before `endCurrentSession()` clears it — the hand-off below needs it.
        let session = currentSessionMetadata

        // Task 069: surfaced *before* short-form generation starts, not after. By this
        // line the long-form file is written, validated and imported — this task's
        // rule 2. Everything below is derived work that must never be able to change
        // that outcome.
        if state == .finished {
            lastRecordingURL = await service.outputFileURL()
        } else {
            errorMessage = await service.lastError?.message
        }

        // Task 070 requirement 1: the recording flow ends here. Diagnostics and the group
        // are written immediately rather than after generation, so an app killed during
        // generation still leaves a complete, grouped long-form recording behind.
        let diagnosticsID = await recordDiagnostics(startTime: startTime, endTime: endTime)
        let groupID = await recordGroup(startTime: startTime, endTime: endTime)
        await endCurrentSession()

        // Requirement 2: handed off and deliberately **not** awaited — the user is free
        // the moment the long-form file is safe.
        handOffShortGeneration(
            startTime: startTime,
            endTime: endTime,
            session: session,
            groupID: groupID,
            diagnosticsID: diagnosticsID
        )
    }

    /// Requirement 2/3: passes the finished long-form file to `ShortGenerationCoordinator`
    /// and returns. That coordinator is owned by the app root, so the job survives the
    /// user leaving the camera screen.
    private func handOffShortGeneration(
        startTime: Date,
        endTime: Date,
        session: RecordingSessionMetadata?,
        groupID: String?,
        diagnosticsID: String?
    ) {
        guard let session,
              session.recordingMode == .dual,
              state == .finished,
              let sourceURL = lastRecordingURL,
              let coordinator = shortGenerationCoordinator else { return }

        Task { @MainActor in
            coordinator.start(ShortGenerationCoordinator.Request(
                sourceURL: sourceURL,
                sessionID: session.sessionID,
                sessionMetadata: session,
                fps: await service.activeFPS,
                recordingStartTime: startTime,
                recordingDuration: endTime.timeIntervalSince(startTime),
                groupID: groupID,
                diagnosticsID: diagnosticsID
            ))
        }
    }

    /// Reads `RecordingService.writerStatuses` for the two known dual-mode profiles and
    /// publishes display text for each — `nil` when that profile isn't currently active
    /// (i.e. `.single` mode), which hides the corresponding UI row (requirement 8).
    private func refreshDualStatuses() async {
        let statuses = await service.writerStatuses
        longFormStatusText = statuses[.longForm].map(Self.dualStatusText)
        shortFormStatusText = statuses[.shortForm].map(Self.dualStatusText)
    }

    private static func dualStatusText(_ status: DualWriterStatus) -> String {
        switch status.state {
        case .idle: "READY"
        case .preparing: "PREPARING"
        case .recording: "RECORDING"
        case .stopping: "STOPPING"
        case .finished: "SUCCESS"
        case .failed: "FAILED"
        }
    }

    /// Called by `RecordingInterruptionMonitor` when an interruption begins. Pauses the
    /// recording (if one is active) and preserves a checkpoint — never resumes anything.
    func handleInterruptionBegan(_ source: InterruptionSource) async {
        interruptionStatus = .interrupted(source)
        interruptionOccurredThisSession = true
        await service.pauseRecording()
    }

    /// Called when the interruption ends. Only updates the displayed status — the
    /// recording stays paused.
    ///
    /// Task 051 requirement 6: the user-facing resume path is removed, so this view
    /// model no longer exposes `resumeRecording()` at all. `RecordingService` keeps its
    /// own `resumeRecording()` as an engine capability — it is what a future crash- or
    /// interruption-recovery feature would build on (CLAUDE.md rules 21-24 require that
    /// path stay open), it just has no UI attached to it now.
    ///
    /// Nothing here ever resumes automatically, which was Task 017's requirement 8/11
    /// and still holds — more strongly than before, since there is now no caller at all.
    func handleInterruptionEnded() {
        guard interruptionStatus != .none else { return }
        interruptionStatus = .ended
    }

    /// Builds and saves a `RecordingDiagnostics` record for the session that just
    /// ended (success or failure) — one file per session (Task 018 requirement 5).
    @discardableResult
    private func recordDiagnostics(startTime: Date, endTime: Date) async -> String? {
        let snapshot = await service.performanceMonitor.snapshot
        let peakMemory = await service.performanceMonitor.peakMemoryUsageBytes
        let availableStorage = await service.performanceMonitor.currentAvailableStorageBytes() ?? 0
        let checkpointCount = await service.checkpointSaveCount
        let resolution = await service.activeQuality
        let fps = await service.activeFPS

        let recoveryStatus: DiagnosticsRecoveryStatus
        if state == .finished {
            recoveryStatus = interruptionOccurredThisSession ? .completedAfterInterruption : .completedNormally
        } else {
            recoveryStatus = .failed
        }

        let diagnostics = RecordingDiagnostics(
            id: UUID().uuidString,
            recordingStartTime: startTime,
            recordingEndTime: endTime,
            recordingDuration: endTime.timeIntervalSince(startTime),
            resolution: resolution,
            fps: fps,
            averageWriteLatency: snapshot.averageWriteLatency,
            droppedVideoFrames: snapshot.droppedVideoFrames,
            droppedAudioBuffers: snapshot.droppedAudioBuffers,
            peakMemoryUsageBytes: peakMemory,
            availableStorageBytes: availableStorage,
            checkpointCount: checkpointCount,
            recoveryStatus: recoveryStatus,
            deliveredVideoFrames: await service.performanceMonitor.deliveredVideoFrameCount,
            droppedBeforeConsumer: await service.performanceMonitor.droppedBeforeConsumerCount,
            savedNominalFrameRate: await service.lastSavedNominalFrameRate,
            writerStats: await service.lastWriterAppendStats,
            droppedFrameReasons: await service.performanceMonitor.dropReasonCounts,
            // Task 063 item 4: the setting `CameraService` read when it configured the
            // video output for this recording. Same source (`UserDefaults`), and it can
            // only change from the 진단 screen while no recording is running, so what is
            // stored here is what was in force while these numbers were measured.
            lateFrameHandling: lateFrameHandlingSettingsService.load().mode,
            // Task 064: the encoder condition, alongside the ground truth read back from
            // the file itself — a codec setting says what was requested, the file's own
            // level says what the hardware encoder actually ran at.
            videoCodecPreference: encoderSettingsService.load().codec,
            keyFrameIntervalSeconds: encoderSettingsService.load().keyFrameInterval.rawValue,
            bitratePreset: bitratePresetSettingsService.load().preset,
            savedVideoFormat: await service.lastSavedVideoFormat,
            encoderDecisions: await service.encoderDecisions,
            savedVideoFormatsByProfile: await service.savedVideoFormatsByProfile,
            savedFrameRatesByProfile: await service.savedFrameRatesByProfile,
            // Task 066 item 1: read from the monitor rather than sampled here — by the
            // time this runs the recording is over, so `ProcessInfo` would report the
            // post-recording state, not the one the recording actually ran under.
            thermalStateAtStart: await service.performanceMonitor.thermalStateAtStart.reportName,
            peakThermalState: await service.performanceMonitor.peakThermalState.reportName,
            thermalStateAtEnd: await service.performanceMonitor.thermalStateAtEnd.reportName,
            dropSamples: await service.performanceMonitor.dropSamples,
            dropAttachmentKeys: await service.performanceMonitor.dropAttachmentKeys.sorted(),
            // Task 068: read from the service, which pinned it when the writers were
            // built — not from the settings store, which the user may have toggled
            // between this recording ending and the diagnostics being written.
            cropBackend: await service.activeCropBackend,
            // Task 070: filled in later by `ShortGenerationCoordinator`, which updates
            // this record once generation finishes. Recording no longer waits for it.
            shortGeneration: nil
        )
        await diagnosticsService.save(diagnostics)
        // Same reasoning as `recordGroup` — matched by id, never by timestamp.
        return diagnostics.id
    }

    /// Task 025 requirement 2: the single place that removes the current session from
    /// `InternalVideoLibraryService.pendingSessions`, called from every exit path a
    /// recording attempt can take — clean finish, `prepareRecording()` failure,
    /// `startRecording()` failure, and cancellation before `.recording` was reached.
    /// A no-op if no session is pending, so it's always safe to call defensively.
    private func endCurrentSession() async {
        guard let session = currentSessionMetadata else { return }
        await libraryService.endSession(session.sessionID)
        currentSessionMetadata = nil
        currentSessionID = nil
    }

    /// Builds and saves a `RecordingGroup` for the session that just ended, referencing
    /// whichever `VideoRecord`s it actually produced — it never creates, copies, or
    /// moves a `VideoRecord`, only looks up which ones already exist so the group can
    /// point at them by `id`.
    ///
    /// Task 024: matches by `sessionID` exclusively — no time window, no aspect-ratio
    /// guessing, no filename comparison (requirement 5). This is possible because
    /// `startRecording()` already told `InternalVideoLibraryService` about this exact
    /// session via `beginSession(_:)`, so every `VideoRecord` it just imported already
    /// carries this session's `sessionID`/`outputProfile` — no searching required.
    @discardableResult
    private func recordGroup(startTime: Date, endTime: Date) async -> String? {
        guard let session = currentSessionMetadata else { return nil }
        let statuses = await service.writerStatuses

        let sessionRecords = ((try? await libraryService.loadAllRecords()) ?? [])
            .filter { $0.sessionID == session.sessionID }

        func member(for profile: OutputProfile, status: DualWriterStatus?) -> RecordingGroupMember? {
            guard let status else { return nil }
            guard status.state == .finished else { return .failed }
            guard let record = sessionRecords.first(where: { $0.outputProfile == profile }) else { return nil }
            return .succeeded(videoRecordID: record.id)
        }

        let longMember: RecordingGroupMember?
        let shortMember: RecordingGroupMember?

        switch session.recordingMode {
        case .single:
            // Requirement 2: "as before" — a failed single recording produced no
            // `VideoRecord` and still shows nothing new now.
            if statuses.values.first?.state == .finished {
                longMember = sessionRecords.first.map { .succeeded(videoRecordID: $0.id) }
            } else {
                longMember = nil
            }
            shortMember = nil

        case .dual:
            longMember = member(for: .longForm, status: statuses[.longForm])
            // Task 069: there is no short-form writer any more, so there is no
            // `statuses[.shortForm]` to read. Membership now comes from what
            // post-processing actually produced, matched by `sessionID` +
            // `outputProfile` exactly as before — identifier-first, never inferred from
            // time or filename (CLAUDE.md rule 62).
            // Task 070: the group is written the moment recording stops, before
            // generation has produced anything, so an app killed mid-generation still
            // leaves a complete long-form group behind — which was not true in Task 069,
            // where the group waited for generation. The short-form member is filled in
            // by `ShortGenerationCoordinator.attachShortToGroup` when the generated file
            // is imported.
            shortMember = nil
        }

        guard longMember != nil || shortMember != nil else { return nil }

        let group = RecordingGroup(
            id: UUID().uuidString,
            createdAt: startTime,
            recordingMode: session.recordingMode,
            longRecording: longMember,
            shortRecording: shortMember,
            duration: endTime.timeIntervalSince(startTime),
            outputMode: session.outputMode
        )
        await groupService.save(group)
        // Task 072 P0-1: returned so the generation job can reference this group by its
        // **id**. Task 070 matched it by `createdAt` instead, which cannot work — both
        // stores encode dates as `.iso8601`, which truncates to whole seconds, so an
        // in-memory `Date` never equalled the reloaded one and the short-form output was
        // never attached to its group (CLAUDE.md rule 62: time is not an identifier).
        return group.id
    }

    private static func format(seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    /// Task 034: captures `self` weakly, matching the pattern already used by
    /// `RecordingPerformanceMonitor.startMonitoring()` — without this, `self` (via
    /// `durationTask`) would hold a strong reference to a closure that itself holds a
    /// strong reference back to `self`, a reference cycle that only resolves once the
    /// loop is cancelled. `deinit` alone can't break it, since `deinit` never runs while
    /// the cycle exists — cancellation has to come from outside instead (which
    /// `stopDurationTimer()` already does on every normal recording-stop path, but a
    /// future caller that forgets to call it would otherwise leak this view model).
    private func startDurationTimer() {
        duration = 0
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.duration += 1
                self.performanceSnapshot = await self.service.performanceMonitor.snapshot
                await self.refreshDualStatuses()
            }
        }
    }

    private func stopDurationTimer() {
        durationTask?.cancel()
        durationTask = nil
    }

    deinit {
        durationTask?.cancel()
    }
}
