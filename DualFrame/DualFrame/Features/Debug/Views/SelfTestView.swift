//
//  SelfTestView.swift
//  DualFrame
//

#if DEBUG
import SwiftUI

/// Automated Self Test (Task 030) — runs `SelfTestService` and shows PASS/WARNING/FAIL
/// for each core component. Debug builds only: the entire file is wrapped in `#if
/// DEBUG`, matching `RecordingDebugView`'s pattern, so nothing here is compiled into
/// a Release build. Read-only — running it never starts a recording or changes a
/// setting; the only action available is re-running the same checks.
struct SelfTestView: View {
    let libraryService: InternalVideoLibraryService
    @ObservedObject var externalStorageViewModel: ExternalStorageViewModel

    @State private var items: [SelfTestItem] = []
    @State private var isRunning = false
    /// Task 031 requirement 4.
    @State private var lastRunAt: Date?
    @State private var showFailedOnly = false

    private var displayedItems: [SelfTestItem] {
        showFailedOnly ? items.filter { $0.status != .pass } : items
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("버전", value: SelfTestService.version)
                    LabeledContent("마지막 실행", value: lastRunAt?.formatted(date: .abbreviated, time: .standard) ?? "--")
                    Toggle("실패/경고만 보기", isOn: $showFailedOnly)
                }

                if items.isEmpty {
                    Text(isRunning ? "실행 중…" : "아직 결과 없음")
                        .foregroundStyle(.secondary)
                } else if displayedItems.isEmpty {
                    Text("실패나 경고 없음 — 모두 통과했습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedItems) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                if let detail = item.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let message = item.status.message {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            statusBadge(for: item.status)
                        }
                    }
                }
            }
            .navigationTitle("자가 진단")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("실행") {
                        Task { await runSelfTest() }
                    }
                    .disabled(isRunning)
                }
            }
        }
        .task {
            await runSelfTest()
        }
    }

    private func runSelfTest() async {
        isRunning = true
        let service = SelfTestService()
        items = await service.run(libraryService: libraryService, externalStorageViewModel: externalStorageViewModel)
        lastRunAt = Date()
        isRunning = false
    }

    @ViewBuilder
    private func statusBadge(for status: SelfTestStatus) -> some View {
        switch status {
        case .pass:
            Label("PASS", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning:
            Label("WARNING", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .fail:
            Label("FAIL", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
#endif
