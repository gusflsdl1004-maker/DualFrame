//
//  RecordingOutputModeView.swift
//  DualFrame
//

import SwiftUI

/// Task 042 (revised): replaces the old Single/Dual Recording picker
/// (`RecordingModeView`, still present unchanged for internal/backward-compat
/// reasons but no longer linked to from Settings) — the user only ever sees "Long만
/// 저장" / "Long + Short 저장" here, never "Single"/"Dual" (requirement 1/2). A third
/// "Short만 저장" option was removed before merge: `RecordingService` has no real
/// short-only capability, so offering it would have meant the app silently recorded
/// both outputs while claiming to record only one. Pushed from the Settings screen,
/// so it has no `NavigationStack` of its own (matches `RecordingQualityView`).
struct RecordingOutputModeView: View {
    @StateObject private var viewModel = RecordingOutputModeViewModel()

    var body: some View {
        Form {
            Section {
                ForEach(RecordingOutputMode.allCases) { mode in
                    modeRow(mode)
                }
            } header: {
                Text("저장 방식")
            }
        }
        .navigationTitle("저장 방식")
    }

    private func modeRow(_ mode: RecordingOutputMode) -> some View {
        Button {
            viewModel.settings.outputMode = mode
        } label: {
            HStack {
                Text(mode.title)
                    .foregroundStyle(.primary)
                Spacer()
                if viewModel.settings.outputMode == mode {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RecordingOutputModeView()
    }
}
