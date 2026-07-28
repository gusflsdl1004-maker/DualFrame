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

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text(isRunning ? "Running…" : "No results yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
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
            .navigationTitle("Self Test")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Run") {
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
