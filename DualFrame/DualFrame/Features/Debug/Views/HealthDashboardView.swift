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
    @State private var selfTestSummaryText = "실행 중…"

    var body: some View {
        NavigationStack {
            Form {
                Section("권한") {
                    LabeledContent("카메라", value: permissionText(permissionViewModel.cameraStatus))
                    LabeledContent("마이크", value: permissionText(permissionViewModel.microphoneStatus))
                    LabeledContent("사진", value: photosStatusText)
                }

                Section("저장소") {
                    LabeledContent("내부 보관함", value: internalLibraryStatusText)
                    LabeledContent("외장 저장소", value: externalStorageStatusText)
                }

                Section("녹화") {
                    LabeledContent("녹화 상태", value: recordingViewModel.displayStatusText)
                    LabeledContent("녹화 모드", value: recordingModeViewModel.settings.mode.title)
                    LabeledContent(
                        "해상도",
                        value: activeQuality.map { "\($0.dimensions.width)×\($0.dimensions.height)" } ?? "--"
                    )
                    LabeledContent("FPS", value: activeFPS?.title ?? "--")
                    LabeledContent("카메라 방향", value: cameraPosition.title)
                }

                Section("기록") {
                    LabeledContent("마지막 녹화", value: lastRecordingText)
                    LabeledContent("마지막 내보내기", value: "여기서는 추적하지 않음 — 보관함 참고")
                    LabeledContent("체크포인트", value: checkpointTimeText)
                }

                Section("상태") {
                    LabeledContent("복구 상태", value: recoveryStatusText)
                    LabeledContent("진단 상태", value: diagnosticsStatusText)
                    LabeledContent("자가 진단 결과", value: selfTestSummaryText)
                }
            }
            .navigationTitle("상태 대시보드")
        }
        .task {
            await refreshAll()
        }
    }

    private func permissionText(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: "허용됨"
        case .denied: "거부됨"
        case .notDetermined: "미결정"
        }
    }

    private var externalStorageStatusText: String {
        switch externalStorageViewModel.status {
        case .connected: externalStorageViewModel.device?.name ?? "연결됨"
        case .disconnected: "연결 안 됨"
        case .unavailable: "사용 불가"
        }
    }

    private var recoveryStatusText: String {
        switch recoveryViewModel.status {
        case .checking: "확인 중…"
        case .recoveryAvailable: "복구 가능"
        case .noRecoveryNeeded: "복구할 항목 없음"
        case .corrupted: "체크포인트 손상됨"
        }
    }

    private var diagnosticsStatusText: String {
        guard let latest = diagnosticsViewModel.sessions.first else {
            return "기록된 세션 없음"
        }
        return "\(latest.recoveryStatus.title) (\(diagnosticsViewModel.sessions.count)개 세션)"
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
            internalLibraryStatusText = "정상 (\(records.count)개 녹화)"
            if let mostRecent = records.max(by: { $0.createdAt < $1.createdAt }) {
                lastRecordingText = mostRecent.createdAt.formatted(date: .abbreviated, time: .shortened)
            } else {
                lastRecordingText = "아직 없음"
            }
        } catch {
            internalLibraryStatusText = "접근 불가"
            lastRecordingText = "--"
        }

        let selfTestService = SelfTestService()
        let results = await selfTestService.run(libraryService: libraryService, externalStorageViewModel: externalStorageViewModel)
        let failCount = results.filter { if case .fail = $0.status { true } else { false } }.count
        let warningCount = results.filter { if case .warning = $0.status { true } else { false } }.count
        if failCount > 0 {
            selfTestSummaryText = "실패 \(failCount)건, 경고 \(warningCount)건"
        } else if warningCount > 0 {
            selfTestSummaryText = "경고 \(warningCount)건"
        } else {
            selfTestSummaryText = "\(results.count)개 항목 모두 통과"
        }
    }

    private func photosPermissionText(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "허용됨"
        case .limited: "제한적 허용"
        case .notDetermined: "미결정"
        case .denied, .restricted: "거부됨"
        @unknown default: "알 수 없음"
        }
    }
}
#endif
