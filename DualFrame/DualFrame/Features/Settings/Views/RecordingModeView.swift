//
//  RecordingModeView.swift
//  DualFrame
//

import SwiftUI

/// Lets the user pick a recording mode. Pushed from the Settings screen, so it has
/// no `NavigationStack` of its own (matches `RecordingQualityView`).
///
/// Dual Recording is selectable as of Task 019 — `RecordingService` now drives two
/// independent writers (long-form + short-form) when this is chosen. It was disabled
/// ("Coming Soon") in Task 018, before that engine existed.
struct RecordingModeView: View {
    @StateObject private var viewModel = RecordingModeViewModel()

    var body: some View {
        Form {
            Section {
                modeRow(.single)
                modeRow(.dual)
            } header: {
                Text("Recording Mode")
            } footer: {
                Text("Dual Recording saves two files per session — a long-form (16:9) and a short-form (9:16) — both to the internal library.")
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
}

#Preview {
    NavigationStack {
        RecordingModeView()
    }
}
