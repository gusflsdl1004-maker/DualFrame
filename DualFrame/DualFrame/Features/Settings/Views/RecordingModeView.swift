//
//  RecordingModeView.swift
//  DualFrame
//

import SwiftUI

/// Lets the user pick a recording mode. Pushed from the Settings screen, so it has
/// no `NavigationStack` of its own (matches `RecordingQualityView`).
///
/// Dual Recording is visible but disabled (requirement 8) — the pipeline architecture
/// for it exists (`DualRecordingCoordinator`, `OutputProfile`) but nothing yet actually
/// records a second output, so it can't be selected.
struct RecordingModeView: View {
    @StateObject private var viewModel = RecordingModeViewModel()

    var body: some View {
        Form {
            Section("Recording Mode") {
                modeRow(.single)
                dualRecordingRow
            }
        }
        .navigationTitle("Recording Mode")
    }

    private func modeRow(_ mode: RecordingMode) -> some View {
        Button {
            viewModel.settings.mode = mode
        } label: {
            HStack {
                Text(mode.title)
                    .foregroundStyle(.primary)
                Spacer()
                if viewModel.settings.mode == mode {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private var dualRecordingRow: some View {
        Button {
            // Intentionally does nothing — Dual Recording isn't implemented yet.
        } label: {
            HStack {
                Text("Dual Recording")
                Spacer()
                Text("Coming Soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(true)
    }
}

#Preview {
    NavigationStack {
        RecordingModeView()
    }
}
