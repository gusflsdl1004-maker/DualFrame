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
        List(viewModel.sessions) { session in
            NavigationLink {
                DiagnosticsDetailView(diagnostics: session)
            } label: {
                sessionRow(session)
            }
        }
        .overlay {
            if viewModel.sessions.isEmpty {
                ContentUnavailableView("No Recording Sessions", systemImage: "chart.bar.doc.horizontal")
            }
        }
        .navigationTitle("Diagnostics")
        .task {
            await viewModel.refresh()
        }
    }

    private func sessionRow(_ session: RecordingDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.recordingStartTime.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            Text("\(formattedDuration(session.recordingDuration)) · \(session.resolution.title) · \(session.fps.title)")
                .font(.caption)
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
