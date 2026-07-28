//
//  RecordingFPSView.swift
//  DualFrame
//

import SwiftUI

/// Lets the user pick a preferred recording frame rate. Pushed from the Settings
/// screen, so it has no `NavigationStack` of its own (matches `RecordingQualityView`).
struct RecordingFPSView: View {
    @StateObject private var viewModel = RecordingFPSViewModel()

    var body: some View {
        Form {
            Section("녹화 프레임레이트") {
                ForEach(RecordingFPS.allCases) { fps in
                    fpsRow(fps)
                }
            }
        }
        .navigationTitle("녹화 프레임레이트")
    }

    private func fpsRow(_ fps: RecordingFPS) -> some View {
        Button {
            viewModel.settings.selectedFPS = fps
        } label: {
            HStack {
                Text(fps.title)
                    .foregroundStyle(.primary)
                Spacer()
                if viewModel.settings.selectedFPS == fps {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RecordingFPSView()
    }
}
