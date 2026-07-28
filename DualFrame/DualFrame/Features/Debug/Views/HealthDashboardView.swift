//
//  HealthDashboardView.swift
//  DualFrame
//

#if DEBUG
import SwiftUI
import Photos

/// App Health Dashboard (Task 032) — a single debug-only screen summarizing overall
/// app health, so a tester doesn't have to open Settings, the Library, and the
/// Recording Debug panel separately just to get a snapshot. Every value here comes
/// from an existing service/ViewModel — this view adds no new business logic, cannot
/// change anything (read-only, no controls other than the Self Test re-run button it
/// already exposes elsewhere), and never starts a recording. Debug builds only.
struct HealthDashboardView: View {
    @ObservedObject var permissionViewModel: CameraPermissionViewModel
    @ObservedObject var recordingViewModel: RecordingViewModel
    @ObservedObject var recordingModeViewModel: RecordingModeViewModel
    @ObservedObject var externalStorageViewModel: ExternalStorageViewModel
    let libraryService: InternalVideoLibraryService
    let dualRecordingCoordinator: DualRecordingCoordinator
    let cameraPosition: CameraPosition
    let activeQuality: RecordingQuality?
    let activeFPS: RecordingFPS?

    @StateObject private var recoveryViewModel = RecoveryViewModel(checkpointStore: RecordingCheckpointStore())
    @StateObject private var diagnosticsViewModel = DiagnosticsViewModel()

    @State private var photosStatusText = "--"
    @State private var internalLibraryStatusText = "--"
    @State private var lastRecordingText = "--"
    @State private var checkpointTimeText = "--"
    @State private var selfTestSummaryText = "Running…"

    var body: some View {
        NavigationStack {
            Form {
                Section("Permissions") {
                    LabeledContent("Camera", value: permissionText(permissionViewModel.cameraStatus))
                    LabeledContent("Microphone", value: permissionText(permissionViewModel.microphoneStatus))
                    LabeledContent("Photos", value: photosStatusText)
                }

                Section("Storage") {
                    LabeledContent("Internal Library", value: internalLibraryStatusText)
                    LabeledContent("External Storage", value: externalStorageStatusText)
                }

                Section("Recording") {
                    LabeledContent("Recording State", value: recordingViewModel.displayStatusText)
                    LabeledContent("Recording Mode", value: recordingModeViewModel.settings.mode.title)
                    LabeledContent(
                        "Resolution",
                        value: activeQuality.map { "\($0.dimensions.width)×\($0.dimensions.height)" } ?? "--"
                    )
                    LabeledContent("FPS", value: activeFPS?.title ?? "--")
                    LabeledContent("Camera Position", value: cameraPosition.title)
                }

                Section("History") {
                    LabeledContent("Last Recording", value: lastRecordingText)
                    LabeledContent("Last Export", value: "Not tracked here — see Library")
                    LabeledContent("Checkpoint", value: checkpointTimeText)
                }

                Section("Status") {
                    LabeledContent("Recovery Status", value: recoveryStatusText)
                    LabeledContent("Diagnostics Status", value: diagnosticsStatusText)
                    LabeledContent("Self Test Result", value: selfTestSummaryText)
                }
            }
            .navigationTitle("Health Dashboard")
        }
        .task {
            await refreshAll()
        }
    }

    private func permissionText(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not Determined"
        }
    }

    private var externalStorageStatusText: String {
        switch externalStorageViewModel.status {
        case .connected: externalStorageViewModel.device?.name ?? "Connected"
        case .disconnected: "Not Connected"
        case .unavailable: "Unavailable"
        }
    }

    private var recoveryStatusText: String {
        switch recoveryViewModel.status {
        case .checking: "Checking…"
        case .recoveryAvailable: "Recovery Available"
        case .noRecoveryNeeded: "No Recovery Needed"
        case .corrupted: "Checkpoint Corrupted"
        }
    }

    private var diagnosticsStatusText: String {
        guard let latest = diagnosticsViewModel.sessions.first else {
            return "No sessions recorded yet"
        }
        return "\(latest.recoveryStatus.title) (\(diagnosticsViewModel.sessions.count) session(s))"
    }

    private func refreshAll() async {
        photosStatusText = photosPermissionText(PhotoLibraryExportService().authorizationStatus())
        await recoveryViewModel.checkRecoveryStatus()
        await diagnosticsViewModel.refresh()

        if let checkpoint = await dualRecordingCoordinator.recordingService.checkpointStore.load() {
            checkpointTimeText = checkpoint.recordingStartTime
                .addingTimeInterval(checkpoint.recordingDuration)
                .formatted(date: .omitted, time: .standard)
        } else {
            checkpointTimeText = "--"
        }

        do {
            let records = try await libraryService.loadAllRecords()
            internalLibraryStatusText = "Reachable (\(records.count) recording(s))"
            if let mostRecent = records.max(by: { $0.createdAt < $1.createdAt }) {
                lastRecordingText = mostRecent.createdAt.formatted(date: .abbreviated, time: .shortened)
            } else {
                lastRecordingText = "None yet"
            }
        } catch {
            internalLibraryStatusText = "Unreachable"
            lastRecordingText = "--"
        }

        let selfTestService = SelfTestService()
        let results = await selfTestService.run(libraryService: libraryService, externalStorageViewModel: externalStorageViewModel)
        let failCount = results.filter { if case .fail = $0.status { true } else { false } }.count
        let warningCount = results.filter { if case .warning = $0.status { true } else { false } }.count
        if failCount > 0 {
            selfTestSummaryText = "\(failCount) FAIL, \(warningCount) WARNING"
        } else if warningCount > 0 {
            selfTestSummaryText = "\(warningCount) WARNING"
        } else {
            selfTestSummaryText = "All \(results.count) checks passed"
        }
    }

    private func photosPermissionText(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "Granted"
        case .limited: "Limited"
        case .notDetermined: "Not Determined"
        case .denied, .restricted: "Denied"
        @unknown default: "Unknown"
        }
    }
}
#endif
