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
                    Section("미리보기") {
                        LabeledContent("세션 ID", value: payload.sessionID)
                        LabeledContent("녹화 상태", value: payload.recordingState)
                        LabeledContent("녹화 모드", value: payload.recordingMode)
                        LabeledContent("해상도", value: payload.resolution)
                        LabeledContent("FPS", value: payload.fps)
                        LabeledContent("방향", value: payload.orientation)
                        LabeledContent("카메라 방향", value: payload.cameraPosition)
                        LabeledContent("체크포인트", value: payload.checkpointTime)
                        LabeledContent("복구 상태", value: payload.recoveryStatus)
                        LabeledContent("실패 원인", value: payload.failureReason)
                        LabeledContent("타임라인 이벤트 수", value: "\(payload.startupTimeline.count)")
                    }
                    Section("상태 대시보드 스냅샷") {
                        LabeledContent("카메라", value: payload.healthDashboardSnapshot.cameraPermission)
                        LabeledContent("마이크", value: payload.healthDashboardSnapshot.microphonePermission)
                        LabeledContent("사진", value: payload.healthDashboardSnapshot.photosPermission)
                        LabeledContent("내부 보관함", value: payload.healthDashboardSnapshot.internalLibraryStatus)
                        LabeledContent("외장 저장소", value: payload.healthDashboardSnapshot.externalStorageStatus)
                        LabeledContent("마지막 녹화", value: payload.healthDashboardSnapshot.lastRecording)
                        LabeledContent("자가 진단", value: payload.healthDashboardSnapshot.selfTestSummary)
                    }
                } else {
                    Text(isBuilding ? "보고서 생성 중…" : "아직 생성되지 않음")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("진단 로그 내보내기")
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
