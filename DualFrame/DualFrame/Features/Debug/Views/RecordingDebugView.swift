//
//  RecordingDebugView.swift
//  DualFrame
//

#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

/// Diagnostics & Developer Panel (Task 026) — a debug-only diagnostics screen showing
/// live internal recording state, so a physical device can be checked at a glance
/// without attaching a debugger. The entire file is wrapped in `#if DEBUG`, so none of
/// it — including this type itself — is compiled into a Release build; there is no
/// runtime check to bypass, only a build-time one.
///
/// Read-only: nothing here can start, stop, or otherwise affect a recording. It only
/// observes already-published values (`RecordingViewModel`/`OrientationManager`/
/// `RecordingModeViewModel`) and reads two already-public, unmodified methods —
/// `RecordingCheckpointStore.load()` (the same one `RecoveryViewModel` already uses)
/// and `RecordingPerformanceMonitor.currentAvailableStorageBytes()` — so this adds no
/// new Recovery/PerformanceMonitor code, only new display.
struct RecordingDebugView: View {
    @ObservedObject var recordingViewModel: RecordingViewModel
    @ObservedObject var orientationManager: OrientationManager
    @ObservedObject var recordingModeViewModel: RecordingModeViewModel
    let activeQuality: RecordingQuality?
    let activeFPS: RecordingFPS?
    let dualRecordingCoordinator: DualRecordingCoordinator

    @State private var lastCheckpointSavedAt: Date?
    @State private var storageRemainingText = "--"
    @State private var activeOutputProfilesText = "--"
    /// Task 029: `RecordingService.lastStartupFailureReason` — a more granular
    /// diagnosis than the single generic error message this app showed before.
    @State private var lastStartupFailureReasonText = "--"
    /// Task 029 requirement 3: the last 30 recording startup events, newest first.
    @State private var timelineEvents: [RecordingStartupEvent] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("세션") {
                    LabeledContent("세션 ID", value: recordingViewModel.currentSessionID?.uuidString ?? "--")
                    LabeledContent("녹화 모드", value: recordingModeViewModel.settings.mode.title)
                    LabeledContent("녹화 상태", value: recordingViewModel.displayStatusText)
                    LabeledContent("활성 출력 프로필", value: activeOutputProfilesText)
                }

                Section("Writer") {
                    LabeledContent("롱폼 Writer 상태", value: recordingViewModel.longFormStatusText ?? "--")
                    LabeledContent("숏폼 Writer 상태", value: recordingViewModel.shortFormStatusText ?? "--")
                }

                Section("캡처") {
                    LabeledContent("방향", value: AppStrings.orientationLabel(orientationManager.deviceOrientation))
                    LabeledContent(
                        "해상도",
                        value: activeQuality.map { "\($0.dimensions.width)×\($0.dimensions.height)" } ?? "--"
                    )
                    LabeledContent("FPS", value: activeFPS?.title ?? "--")
                }

                Section("복구") {
                    LabeledContent(
                        "체크포인트 시간",
                        value: lastCheckpointSavedAt?.formatted(date: .omitted, time: .standard) ?? "--"
                    )
                }

                Section("실패 진단") {
                    LabeledContent("마지막 실패 원인", value: lastStartupFailureReasonText)
                }

                // Task 031 requirement 3: everything needed to diagnose a "Writing the
                // recording failed" occurrence gathered on one screen, so a tester
                // never has to scroll between separate sections to correlate them.
                // Purely additive display — reuses the exact same already-fetched
                // state as the sections above, no new service calls.
                Section {
                    LabeledContent("실패 원인", value: lastStartupFailureReasonText)
                    LabeledContent("녹화 상태", value: recordingViewModel.displayStatusText)
                    LabeledContent("세션 ID", value: recordingViewModel.currentSessionID?.uuidString ?? "--")
                    if timelineEvents.isEmpty {
                        Text("아직 이벤트 없음")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(timelineEvents.suffix(5).reversed()) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(event.stage)
                                        .font(.caption2.bold())
                                }
                                if let detail = event.detail {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("실패 상세")
                } footer: {
                    Text("최근 5개 시작 이벤트입니다 — 전체 30개 기록은 아래 시작 타임라인을 참고하세요.")
                }

                // Task 031 requirement 2: the same fields now shown alongside the
                // Startup Timeline, so a tester reviewing the timeline doesn't have to
                // scroll back up to Session/Writers/Recovery to see current state.
                Section("진단 스냅샷") {
                    LabeledContent("녹화 상태", value: recordingViewModel.displayStatusText)
                    LabeledContent("세션 ID", value: recordingViewModel.currentSessionID?.uuidString ?? "--")
                    LabeledContent("롱폼 Writer 상태", value: recordingViewModel.longFormStatusText ?? "--")
                    LabeledContent("숏폼 Writer 상태", value: recordingViewModel.shortFormStatusText ?? "--")
                    LabeledContent(
                        "체크포인트 시간",
                        value: lastCheckpointSavedAt?.formatted(date: .omitted, time: .standard) ?? "--"
                    )
                    LabeledContent("녹화 모드", value: recordingModeViewModel.settings.mode.title)
                }

                Section("시작 타임라인 (최근 30개)") {
                    if timelineEvents.isEmpty {
                        Text("아직 이벤트 없음")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(timelineEvents.reversed()) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(event.stage)
                                        .font(.caption.bold())
                                }
                                if let detail = event.detail {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("성능") {
                    LabeledContent("메모리 사용량", value: recordingViewModel.memoryStatusText)
                    LabeledContent("드롭된 프레임", value: recordingViewModel.formattedDroppedFrames)
                    LabeledContent("쓰기 지연 시간", value: recordingViewModel.writeStatusText)
                    LabeledContent("남은 저장 공간", value: storageRemainingText)
                }

                Section {
                    LabeledContent("내보내기 상태", value: "여기서는 추적하지 않음 — 보관함 참고")
                } footer: {
                    Text("내보내기 상태는 이 화면이 보는 세션 단위가 아니라 보관함 화면에서 녹화별로 추적됩니다.")
                }
            }
            .navigationTitle("녹화 디버그")
            .toolbar {
                // Task 031 requirement 5: Debug-only JSON export of the current
                // diagnostics snapshot — read-only, no new recording logic. The
                // Transferable's data is generated lazily when the share sheet
                // actually needs it, not on every view refresh.
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        item: DiagnosticsExportDocument(payload: currentDiagnosticsExportPayload),
                        preview: SharePreview("DualFrame Diagnostics")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await refreshCheckpointTimestamp()
                await refreshStorageRemaining()
                await refreshActiveOutputProfiles()
                await refreshFailureReason()
                await refreshTimeline()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Derives "when was the checkpoint last saved" purely from
    /// `RecordingCheckpoint`'s own existing fields (`recordingStartTime +
    /// recordingDuration`, since the checkpoint payload has no separate "saved at"
    /// field of its own) via the already-public, unmodified
    /// `RecordingCheckpointStore.load()` — no new Recovery/Checkpoint code.
    private func refreshCheckpointTimestamp() async {
        guard let checkpoint = await dualRecordingCoordinator.recordingService.checkpointStore.load() else {
            lastCheckpointSavedAt = nil
            return
        }
        lastCheckpointSavedAt = checkpoint.recordingStartTime.addingTimeInterval(checkpoint.recordingDuration)
    }

    private func refreshStorageRemaining() async {
        guard let bytes = await dualRecordingCoordinator.recordingService.performanceMonitor.currentAvailableStorageBytes() else {
            storageRemainingText = "--"
            return
        }
        storageRemainingText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshActiveOutputProfiles() async {
        let profiles = await dualRecordingCoordinator.activeProfiles
        activeOutputProfilesText = profiles.map(\.outputName).joined(separator: ", ")
    }

    /// Task 029 requirement 2: reads `RecordingService.lastStartupFailureReason` —
    /// read-only, added by this task, never itself a decision point in the pipeline.
    private func refreshFailureReason() async {
        let reason = await dualRecordingCoordinator.recordingService.lastStartupFailureReason
        lastStartupFailureReasonText = reason?.description ?? "--"
    }

    /// Task 029 requirement 3: reads the last 30 events from the shared
    /// `RecordingDiagnosticsLogService` both `RecordingService` and `CameraService`
    /// write to.
    private func refreshTimeline() async {
        timelineEvents = await dualRecordingCoordinator.recordingService.diagnosticsLogService.recentEvents()
    }

    /// Task 031 requirement 5: builds the exportable diagnostics snapshot from
    /// state already displayed on this screen — no new data is read or computed
    /// beyond what's already fetched by the refresh loop above.
    private var currentDiagnosticsExportPayload: DiagnosticsExportPayload {
        DiagnosticsExportPayload(
            exportedAt: Date(),
            sessionID: recordingViewModel.currentSessionID?.uuidString ?? "--",
            recordingMode: recordingModeViewModel.settings.mode.title,
            recordingState: recordingViewModel.displayStatusText,
            longWriterStatus: recordingViewModel.longFormStatusText ?? "--",
            shortWriterStatus: recordingViewModel.shortFormStatusText ?? "--",
            checkpointTime: lastCheckpointSavedAt?.formatted(date: .omitted, time: .standard) ?? "--",
            lastFailureReason: lastStartupFailureReasonText,
            timeline: timelineEvents.map {
                DiagnosticsExportPayload.TimelineEventExport(timestamp: $0.timestamp, stage: $0.stage, detail: $0.detail)
            }
        )
    }
}

/// Task 031 requirement 5: the JSON shape shared out of the debug panel. Purely a
/// snapshot for a developer/tester to attach to a bug report — never read back by
/// the app itself.
nonisolated private struct DiagnosticsExportPayload: Codable {
    nonisolated struct TimelineEventExport: Codable {
        let timestamp: Date
        let stage: String
        let detail: String?
    }

    let exportedAt: Date
    let sessionID: String
    let recordingMode: String
    let recordingState: String
    let longWriterStatus: String
    let shortWriterStatus: String
    let checkpointTime: String
    let lastFailureReason: String
    let timeline: [TimelineEventExport]
}

/// Wraps `DiagnosticsExportPayload` as `Transferable` so `ShareLink` can generate the
/// actual JSON `Data` lazily, only when the user taps Share — not on every view refresh.
nonisolated private struct DiagnosticsExportDocument: Transferable {
    let payload: DiagnosticsExportPayload

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
