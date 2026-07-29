//
//  DiagnosticsView.swift
//  DualFrame
//

import SwiftUI

/// Lists every saved recording session's diagnostics, newest first (requirement 7).
/// Pushed from the Settings screen, so it has no `NavigationStack` of its own
/// (matches `ExternalStorageView`/`RecordingQualityView`).
struct DiagnosticsView: View {
    @StateObject private var viewModel = DiagnosticsViewModel()

    var body: some View {
        List {
            // Task 062: the two conditions side by side, which is what the comparison
            // actually needs — scrolling between two detail screens loses the diff.
            Section {
                NavigationLink {
                    DiagnosticsComparisonView(sessions: viewModel.sessions)
                } label: {
                    Label("Long vs Long+Short 비교", systemImage: "square.split.2x1")
                }
            }

            ForEach(viewModel.sessions) { session in
            NavigationLink {
                DiagnosticsDetailView(diagnostics: session)
            } label: {
                sessionRow(session)
            }
            }
        }
        .overlay {
            if viewModel.sessions.isEmpty {
                ContentUnavailableView("녹화 기록이 없습니다", systemImage: "chart.bar.doc.horizontal")
            }
        }
        .navigationTitle("진단")
        .task {
            await viewModel.refresh()
        }
    }

    private func conditionLabel(_ session: RecordingDiagnostics) -> String {
        switch session.writerStats?.count ?? 0 {
        case 0: "조건 미기록"
        case 1: "Long Only"
        default: "Long + Short"
        }
    }

    private func sessionRow(_ session: RecordingDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.recordingStartTime.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            Text("\(formattedDuration(session.recordingDuration)) · \(session.resolution.title) · \(session.fps.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Task 062: which condition this recording was, derived from how many
            // writers actually ran — so the two runs are told apart in the list.
            Text(conditionLabel(session))
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(session.recoveryStatus.title)
                .font(.caption2)
                .foregroundStyle(session.recoveryStatus == .failed ? .red : .secondary)
        }
        .padding(.vertical, 2)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView()
    }
}
