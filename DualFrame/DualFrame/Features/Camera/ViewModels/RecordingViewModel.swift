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
            state = await service.prepareRecording()
            lowStorageWarning = await service.performanceMonitor.lowStorageWarning
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
        }
    }

    func stopRecording(expectsAudioTrack: Bool) async {
        guard state == .recording else { return }
        let startTime = await service.recordingStartTime ?? Date()

        state = await service.stopRecording(expectsAudioTrack: expectsAudioTrack)
        stopDurationTimer()
        lastValidationResult = await service.lastValidationResult
        await refreshDualStatuses()

        let endTime = Date()
        await recordDiagnostics(startTime: startTime, endTime: endTime)
        await recordGroup(startTime: startTime, endTime: endTime)

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

    /// Called by `RecordingInterruptionMonitor` when an interruption begins. Pauses the
    /// recording (if one is active) and preserves a checkpoint — never resumes anything.
    func handleInterruptionBegan(_ source: InterruptionSource) async {
        interruptionStatus = .interrupted(source)
        interruptionOccurredThisSession = true
        await service.pauseRecording()
    }

    /// Called when the interruption ends. Only updates the displayed status — recording
    /// stays paused; nothing here calls `resumeRecording()` (requirement 8, 11).
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

    /// Builds and saves a `RecordingGroup` for the session that just ended (Task 023
    /// requirement 2), referencing whichever `VideoRecord`s the session actually
    /// produced — it never creates, copies, or moves a `VideoRecord`, only looks up
    /// which ones already exist so the group can point at them by `id`.
    ///
    /// `RecordingService` doesn't expose which `VideoRecord` came from which profile
    /// (and this task must not modify it to add that — requirement 8), so profiles are
    /// matched to library records by recency (created during this session's window)
    /// and aspect ratio (short-form is portrait, long-form/single is landscape). This
    /// is a best-effort heuristic, not a guarantee — see the Task 023 report's Known
    /// Issues for what happens when it can't find a confident match (the `VideoRecord`
    /// is never lost; it just shows up ungrouped instead).
    private func recordGroup(startTime: Date, endTime: Date) async {
        let mode = await service.mode
        let statuses = await service.writerStatuses

        var candidates = ((try? await libraryService.loadAllRecords()) ?? [])
            .filter { $0.createdAt >= startTime.addingTimeInterval(-2) && $0.createdAt <= endTime.addingTimeInterval(10) }
            .sorted { $0.createdAt < $1.createdAt }

        func takeMatch(isPortrait: Bool) -> VideoRecord? {
            guard let index = candidates.firstIndex(where: { ($0.resolution.height > $0.resolution.width) == isPortrait }) else {
                return nil
            }
            return candidates.remove(at: index)
        }

        func member(for status: DualWriterStatus?, isPortrait: Bool) -> RecordingGroupMember? {
            guard let status else { return nil }
            guard status.state == .finished else { return .failed }
            guard let record = takeMatch(isPortrait: isPortrait) else { return nil }
            return .succeeded(videoRecordID: record.id)
        }

        let longMember: RecordingGroupMember?
        let shortMember: RecordingGroupMember?

        switch mode {
        case .single:
            // Requirement 2: "as before" — a failed single recording produced no
            // `VideoRecord` before Task 023 and still shows nothing new now.
            if statuses.values.first?.state == .finished {
                longMember = takeMatch(isPortrait: false).map { .succeeded(videoRecordID: $0.id) }
            } else {
                longMember = nil
            }
            shortMember = nil

        case .dual:
            longMember = member(for: statuses[.longForm], isPortrait: false)
            shortMember = member(for: statuses[.shortForm], isPortrait: true)
        }

        guard longMember != nil || shortMember != nil else { return }

        let group = RecordingGroup(
            id: UUID().uuidString,
            createdAt: startTime,
            recordingMode: mode,
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
