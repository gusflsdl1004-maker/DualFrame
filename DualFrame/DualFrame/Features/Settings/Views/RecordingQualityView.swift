//
//  RecordingQualityView.swift
//  DualFrame
//

import SwiftUI

/// Lets the user pick a preferred recording resolution. Pushed from the Settings
/// screen, so it has no `NavigationStack` of its own (matches `ExternalStorageView`).
struct RecordingQualityView: View {
    @StateObject private var viewModel = RecordingQualityViewModel()

    var body: some View {
        Form {
            Section("Recording Quality") {
                ForEach(RecordingQuality.allCases) { quality in
                    qualityRow(quality)
                }
            }
        }
        .navigationTitle("Recording Quality")
    }

    private func qualityRow(_ quality: RecordingQuality) -> some View {
        Button {
            viewModel.settings.selectedQuality = quality
        } label: {
            HStack {
                Text(quality.title)
                    .foregroundStyle(.primary)
                Spacer()
                if viewModel.settings.selectedQuality == quality {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RecordingQualityView()
    }
}
