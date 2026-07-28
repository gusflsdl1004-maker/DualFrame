//
//  CrashReportExportView.swift
//  DualFrame
//

#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

/// Crash Report & Log Export (Task 035) — builds the full diagnostics snapshot via
/// `CrashReportExportService` and lets it be shared out as JSON. Read-only: this
/// screen only displays a preview and offers a Share action, it never starts a
/// recording and never touches `ExportCoordinator` (that type exports *recordings* to
/// Photos/external storage — a completely separate concern from exporting diagnostics
/// text). Debug builds only.
struct CrashReportExportView: View {
    @ObservedObject var recordingViewModel: RecordingViewModel
    @ObservedObject var recordingModeViewModel: RecordingModeViewModel
    @ObservedObject var orientationManager: OrientationManager
    @ObservedObject var permissionViewModel: CameraPermissionViewModel
    @ObservedObject var externalStorageViewModel: ExternalStorageViewModel
    let libraryService: InternalVideoLibraryService
    let dualRecordingCoordinator: DualRecordingCoordinator
    let cameraPosition: CameraPosition
    let activeQuality: RecordingQuality?
    let activeFPS: RecordingFPS?

    @State private var payload: CrashReportPayload?
    @State private var isBuilding = false

    var body: some View {
        NavigationStack {
            Form {
                if let payload {
                    Section("Preview") {
                        LabeledContent("Session ID", value: payload.sessionID)
                        LabeledContent("Recording State", value: payload.recordingState)
                        LabeledContent("Recording Mode", value: payload.recordingMode)
                        LabeledContent("Resolution", value: payload.resolution)
                        LabeledContent("FPS", value: payload.fps)
                        LabeledContent("Orientation", value: payload.orientation)
                        LabeledContent("Camera Position", value: payload.cameraPosition)
                        LabeledContent("Checkpoint", value: payload.checkpointTime)
                        LabeledContent("Recovery Status", value: payload.recoveryStatus)
                        LabeledContent("Failure Reason", value: payload.failureReason)
                        LabeledContent("Timeline Events", value: "\(payload.startupTimeline.count)")
                    }
                    Section("Health Dashboard Snapshot") {
                        LabeledContent("Camera", value: payload.healthDashboardSnapshot.cameraPermission)
                        LabeledContent("Microphone", value: payload.healthDashboardSnapshot.microphonePermission)
                        LabeledContent("Photos", value: payload.healthDashboardSnapshot.photosPermission)
                        LabeledContent("Internal Library", value: payload.healthDashboardSnapshot.internalLibraryStatus)
                        LabeledContent("External Storage", value: payload.healthDashboardSnapshot.externalStorageStatus)
                        LabeledContent("Last Recording", value: payload.healthDashboardSnapshot.lastRecording)
                        LabeledContent("Self Test", value: payload.healthDashboardSnapshot.selfTestSummary)
                    }
                } else {
                    Text(isBuilding ? "Building report…" : "Not built yet")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Crash Report Export")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let payload {
                        ShareLink(
                            item: CrashReportExportDocument(payload: payload),
                            preview: SharePreview("DualFrame Crash Report")
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task {
            await buildReport()
        }
    }

    private func buildReport() async {
        isBuilding = true
        payload = await CrashReportExportService().build(
            recordingViewModel: recordingViewModel,
            recordingModeViewModel: recordingModeViewModel,
            orientationManager: orientationManager,
            permissionViewModel: permissionViewModel,
            externalStorageViewModel: externalStorageViewModel,
            libraryService: libraryService,
            dualRecordingCoordinator: dualRecordingCoordinator,
            cameraPosition: cameraPosition,
            activeQuality: activeQuality,
            activeFPS: activeFPS
        )
        isBuilding = false
    }
}

/// Wraps `CrashReportPayload` as `Transferable` so `ShareLink` generates the actual
/// JSON `Data` lazily, only when the user taps Share.
nonisolated private struct CrashReportExportDocument: Transferable {
    let payload: CrashReportPayload

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { document in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            return (try? encoder.encode(document.payload)) ?? Data()
        }
    }
}
#endif
