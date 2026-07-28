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
                Text("녹화 모드")
            } footer: {
                Text("듀얼 녹화는 한 번의 녹화로 롱폼(16:9)과 숏폼(9:16) 두 개의 파일을 만들어 모두 내부 보관함에 저장합니다.")
            }
        }
        .navigationTitle("녹화 모드")
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
