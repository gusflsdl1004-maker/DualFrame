//
//  RecordingViewModel.swift
//  DualFrame
//

import Combine
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

    var statusText: String {
        switch state {
        case .idle: "READY"
        case .preparing: "PREPARING"
        case .recording: "RECORDING"
        case .stopping: "STOPPING"
        case .finished: "SUCCESS"
        case .failed: "FAILED"
        }
    }

    /// `state` alone stays `.recording` throughout a pause (Task 017's design) — this
    /// combines it with `interruptionStatus` so the UI can clearly distinguish
    /// Recording / Paused / Resume-available (requirement 5), without changing what
    /// `statusText`/`state` themselves mean anywhere else.
    var displayStatusText: String {
        guard state == .recording, interruptionStatus != .none else { return statusText }
        return "PAUSED"
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
        groupService: RecordingGroupService = RecordingGroupService()
    ) {
        self.service = service
        self.dualRecordingCoordinator = dualRecordingCoordinator
        self.cameraService = cameraService
        self.libraryService = libraryService
        self.diagnosticsService = diagnosticsService
        self.groupService = groupService
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

            // Task 024 requirement 2: created exactly once per recording, before it
            // starts — every output this recording produces will be tagged with this
            // sessionID by `InternalVideoLibraryService`, without `RecordingService`
            // ever needing to know sessions exist.
            let metadata = RecordingSessionMetadata(
                sessionID: UUID(),
                startedAt: Date(),
                recordingMode: mode,
                selectedQuality: await service.activeQuality,
                selectedFPS: await service.activeFPS
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
        await recordDiagnostics(startTime: startTime, endTime: endTime)
        await recordGroup(startTime: startTime, endTime: endTime)
        await endCurrentSession()

        if state == .finished {
            lastRecordingURL = await service.outputFileURL()
        } else {
            errorMessage = await service.lastError?.message
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

    /// Called only when the user taps the Resume button (requirement 1) — never
    /// automatically, e.g. never from `handleInterruptionEnded()` below. Un-pauses the
    /// writer(s) via `RecordingService`'s existing extension point and clears the
    /// displayed interruption status so the UI returns to showing "RECORDING". Touches
    /// nothing about the session — `sessionID`, `recordingStartTime`, and any
    /// `RecordingGroup` all stay exactly as they were (requirement 3).
    func resumeRecording() async {
        guard interruptionStatus != .none else { return }
        await service.resumeRecording()
        interruptionStatus = .none
    }

    /// Called by `RecordingInterruptionMonitor` when an interruption begins. Pauses the
    /// recording (if one is active) and preserves a checkpoint — never resumes anything.
    func handleInterruptionBegan(_ source: InterruptionSource) async {
        interruptionStatus = .interrupted(source)
        interruptionOccurredThisSession = true
        await service.pauseRecording()
    }

    /// Called when the interruption ends. Only updates the displayed status — recording
    /// stays paused; nothing here calls `resumeRecording()` (requirement 8, 11 from
    /// Task 017; this task's requirement 1 keeps that guarantee — only a user tap on
    /// the Resume button ever calls `resumeRecording()` above).
    func handleInterruptionEnded() {
        guard interruptionStatus != .none else { return }
        interruptionStatus = .ended
    }

    /// Builds and saves a `RecordingDiagnostics` record for the session that just
    /// ended (success or failure) — one file per session (Task 018 requirement 5).
    private func recordDiagnostics(startTime: Date, endTime: Date) async {
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
            recoveryStatus: recoveryStatus
        )
        await diagnosticsService.save(diagnostics)
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
    private func recordGroup(startTime: Date, endTime: Date) async {
        guard let session = currentSessionMetadata else { return }
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
            shortMember = member(for: .shortForm, status: statuses[.shortForm])
        }

        guard longMember != nil || shortMember != nil else { return }

        let group = RecordingGroup(
            id: UUID().uuidString,
            createdAt: startTime,
            recordingMode: session.recordingMode,
            longRecording: longMember,
            shortRecording: shortMember,
            duration: endTime.timeIntervalSince(startTime)
        )
        await groupService.save(group)
    }

    private static func format(seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func startDurationTimer() {
        duration = 0
        durationTask?.cancel()
        durationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                duration += 1
                performanceSnapshot = await service.performanceMonitor.snapshot
                await refreshDualStatuses()
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
