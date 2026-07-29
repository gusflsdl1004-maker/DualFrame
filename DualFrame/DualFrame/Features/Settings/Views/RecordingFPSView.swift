//
//  RecordingFPSView.swift
//  DualFrame
//

import SwiftUI

/// Lets the user pick a preferred recording frame rate. Pushed from the Settings
/// screen, so it has no `NavigationStack` of its own (matches `RecordingQualityView`).
struct RecordingFPSView: View {
    @StateObject private var viewModel = RecordingFPSViewModel()
    /// Task 039 requirement 5: FPS support depends on which resolution is currently
    /// selected — the same camera can support 60fps at Full HD but only 30fps at 4K.
    private let capabilityService = DeviceCapabilityService()
    private let currentQuality = RecordingQualitySettingsService().load().selectedQuality

    var body: some View {
        Form {
            Section {
                ForEach(RecordingFPS.allCases) { fps in
                    fpsRow(fps)
                }
            } header: {
                Text("녹화 프레임레이트")
            } footer: {
                Text("현재 화질(\(currentQuality.title))에서 지원하지 않는 프레임레이트는 선택할 수 없습니다.")
            }
        }
        .navigationTitle("녹화 프레임레이트")
    }

    private func fpsRow(_ fps: RecordingFPS) -> some View {
        let supported = capabilityService.isSupported(fps, at: currentQuality)
        return Button {
            viewModel.settings.selectedFPS = fps
        } label: {
            HStack {
                Text(fps.title)
                    .foregroundStyle(supported ? .primary : .secondary)
                if !supported {
                    Text("(지원 안 함)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.settings.selectedFPS == fps {
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
        RecordingFPSView()
    }
}
