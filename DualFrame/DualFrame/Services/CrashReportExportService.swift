//
//  CrashReportExportService.swift
//  DualFrame
//

#if DEBUG
import Foundation
import Photos

/// Crash Report & Log Export (Task 035) — gathers every field the debug diagnostics
/// screens already display into one JSON snapshot, so it can be attached to a bug
/// report. Entirely read-only: every value here is read from an already-existing
/// service/ViewModel (`RecordingService.diagnosticsLogService`, `RecordingCheckpointStore`,
/// `RecoveryViewModel`, `SelfTestService`, the permission/library/external-storage
/// services), and nothing here writes to any of them. Does not touch
/// `ExportCoordinator` (that's for exporting *recordings*, not diagnostics) or any
/// recording logic. Debug builds only — the entire file is wrapped in `#if DEBUG`.
nonisolated struct CrashReportPayload: Codable {
    struct TimelineEventExport: Codable {
        let timestamp: Date
        let stage: String
        let detail: String?
    }

    struct HealthSnapshot: Codable {
        let cameraPermission: String
        let microphonePermission: String
        let photosPermission: String
        let internalLibraryStatus: String
        let externalStorageStatus: String
        let lastRecording: String
        let selfTestSummary: String
    }

    let exportedAt: Date
    let sessionID: String
    let recordingState: String
    let recordingMode: String
    let resolution: String
    let fps: String
    let orientation: String
    let cameraPosition: String
    let longWriterStatus: String
    let shortWriterStatus: String
    let checkpointTime: String
    let recoveryStatus: String
    let failureReason: String
    let startupTimeline: [TimelineEventExport]
    let healthDashboardSnapshot: HealthSnapshot
}

struct CrashReportExportService {
    func build(
        recordingViewModel: RecordingViewModel,
        recordingModeViewModel: RecordingModeViewModel,
        orientationManager: OrientationManager,
        permissionViewModel: CameraPermissionViewModel,
        externalStorageViewModel: ExternalStorageViewModel,
        libraryService: InternalVideoLibraryService,
        dualRecordingCoordinator: DualRecordingCoordinator,
        cameraPosition: CameraPosition,
        activeQuality: RecordingQuality?,
        activeFPS: RecordingFPS?
    ) async -> CrashReportPayload {
        let recordingService = dualRecordingCoordinator.recordingService

        let failureReason = await recordingService.lastStartupFailureReason?.description ?? "--"
        let timeline = await recordingService.diagnosticsLogService.recentEvents().map {
            CrashReportPayload.TimelineEventExport(timestamp: $0.timestamp, stage: $0.stage, detail: $0.detail)
        }

        let checkpointTime: String
        if let checkpoint = await recordingService.checkpointStore.load() {
            checkpointTime = checkpoint.recordingStartTime
                .addingTimeInterval(checkpoint.recordingDuration)
                .formatted(date: .abbreviated, time: .standard)
        } else {
            checkpointTime = "--"
        }

        let recoveryViewModel = RecoveryViewModel(checkpointStore: RecordingCheckpointStore())
        await recoveryViewModel.checkRecoveryStatus()
        let recoveryStatus = Self.recoveryStatusText(recoveryViewModel.status)

        let healthSnapshot = await buildHealthSnapshot(
            permissionViewModel: permissionViewModel,
            externalStorageViewModel: externalStorageViewModel,
            libraryService: libraryService
        )

        return CrashReportPayload(
            exportedAt: Date(),
            sessionID: recordingViewModel.currentSessionID?.uuidString ?? "--",
            recordingState: recordingViewModel.displayStatusText,
            recordingMode: recordingModeViewModel.settings.mode.title,
            resolution: activeQuality.map { "\($0.dimensions.width)×\($0.dimensions.height)" } ?? "--",
            fps: activeFPS?.title ?? "--",
            orientation: Self.orientationText(orientationManager.deviceOrientation),
            cameraPosition: cameraPosition.title,
            longWriterStatus: recordingViewModel.longFormStatusText ?? "--",
            shortWriterStatus: recordingViewModel.shortFormStatusText ?? "--",
            checkpointTime: checkpointTime,
            recoveryStatus: recoveryStatus,
            failureReason: failureReason,
            startupTimeline: timeline,
            healthDashboardSnapshot: healthSnapshot
        )
    }

    @MainActor
    private func buildHealthSnapshot(
        permissionViewModel: CameraPermissionViewModel,
        externalStorageViewModel: ExternalStorageViewModel,
        libraryService: InternalVideoLibraryService
    ) async -> CrashReportPayload.HealthSnapshot {
        let photosStatus = PhotoLibraryExportService().authorizationStatus()

        let internalLibraryStatus: String
        let lastRecording: String
        do {
            let records = try await libraryService.loadAllRecords()
            internalLibraryStatus = "Reachable (\(records.count) recording(s))"
            lastRecording = records.max(by: { $0.createdAt < $1.createdAt })?
                .createdAt.formatted(date: .abbreviated, time: .shortened) ?? "None yet"
        } catch {
            internalLibraryStatus = "Unreachable"
            lastRecording = "--"
        }

        let selfTestResults = await SelfTestService().run(
            libraryService: libraryService,
            externalStorageViewModel: externalStorageViewModel
        )
        let failCount = selfTestResults.filter { if case .fail = $0.status { true } else { false } }.count
        let warningCount = selfTestResults.filter { if case .warning = $0.status { true } else { false } }.count
        let selfTestSummary: String = if failCount > 0 {
            "\(failCount) FAIL, \(warningCount) WARNING"
        } else if warningCount > 0 {
            "\(warningCount) WARNING"
        } else {
            "All \(selfTestResults.count) checks passed"
        }

        return CrashReportPayload.HealthSnapshot(
            cameraPermission: Self.permissionText(permissionViewModel.cameraStatus),
            microphonePermission: Self.permissionText(permissionViewModel.microphoneStatus),
            photosPermission: Self.photosPermissionText(photosStatus),
            internalLibraryStatus: internalLibraryStatus,
            externalStorageStatus: Self.externalStorageStatusText(externalStorageViewModel),
            lastRecording: lastRecording,
            selfTestSummary: selfTestSummary
        )
    }

    private static func permissionText(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not Determined"
        }
    }

    @MainActor
    private static func externalStorageStatusText(_ viewModel: ExternalStorageViewModel) -> String {
        switch viewModel.status {
        case .connected: viewModel.device?.name ?? "Connected"
        case .disconnected: "Not Connected"
        case .unavailable: "Unavailable"
        }
    }

    private static func photosPermissionText(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "Granted"
        case .limited: "Limited"
        case .notDetermined: "Not Determined"
        case .denied, .restricted: "Denied"
        @unknown default: "Unknown"
        }
    }

    private static func orientationText(_ orientation: RecordingOrientation) -> String {
        switch orientation {
        case .portrait: "Portrait"
        case .portraitUpsideDown: "Portrait Upside Down"
        case .landscapeLeft: "Landscape Left"
        case .landscapeRight: "Landscape Right"
        }
    }

    @MainActor
    private static func recoveryStatusText(_ status: RecoveryStatus) -> String {
        switch status {
        case .checking: "Checking…"
        case .recoveryAvailable: "Recovery Available"
        case .noRecoveryNeeded: "No Recovery Needed"
        case .corrupted: "Checkpoint Corrupted"
        }
    }
}
#endif
