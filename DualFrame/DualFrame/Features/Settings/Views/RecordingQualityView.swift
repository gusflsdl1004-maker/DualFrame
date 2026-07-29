//
//  RecordingQualityView.swift
//  DualFrame
//

import SwiftUI

/// Lets the user pick a preferred recording resolution. Pushed from the Settings
/// screen, so it has no `NavigationStack` of its own (matches `ExternalStorageView`).
struct RecordingQualityView: View {
    @StateObject private var viewModel = RecordingQualityViewModel()
    /// Task 039 requirement 5: which resolutions the currently-selected camera
    /// actually supports, so unsupported ones can be disabled here rather than only
    /// discovered once a recording starts.
    private let capabilityService = DeviceCapabilityService()

    var body: some View {
        Form {
            Section {
                ForEach(RecordingQuality.allCases) { quality in
                    qualityRow(quality)
                }
            } header: {
                Text("녹화 화질")
            } footer: {
                Text("이 기기에서 지원하지 않는 화질은 선택할 수 없습니다.")
            }
        }
        .navigationTitle("녹화 화질")
    }

    private func qualityRow(_ quality: RecordingQuality) -> some View {
        let supported = capabilityService.isSupported(quality)
        return Button {
            viewModel.settings.selectedQuality = quality
        } label: {
            HStack {
                Text(quality.title)
                    .foregroundStyle(supported ? .primary : .secondary)
                if !supported {
                    Text("(지원 안 함)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.settings.selectedQuality == quality {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(!supported)
    }
}

#Preview {
    NavigationStack {
        RecordingQualityView()
    }
}
