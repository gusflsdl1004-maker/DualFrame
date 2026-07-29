//
//  BitratePresetView.swift
//  DualFrame
//

import SwiftUI

/// Task 050 requirement 3: picks the recording quality preset. Shows the bitrate each
/// preset actually produces at the currently-selected quality/FPS, so the choice is
/// concrete rather than three abstract words — and because the same
/// `BitrateEstimationService` drives both the encoder and "예상 촬영 가능", the number
/// shown here is the number that will be used.
struct BitratePresetView: View {
    @StateObject private var viewModel = BitratePresetViewModel()
    @State private var currentQuality: RecordingQuality = RecordingQualitySettingsService().load().selectedQuality
    @State private var currentFPS: RecordingFPS = RecordingFPSSettingsService().load().selectedFPS

    var body: some View {
        Form {
            Section {
                ForEach(BitratePreset.allCases) { preset in
                    presetRow(preset)
                }
            } header: {
                Text("녹화 품질")
            } footer: {
                Text("현재 \(currentQuality.title) \(currentFPS.title) 기준 예상 비트레이트입니다. 품질을 높이면 파일 크기와 발열이 함께 늘어납니다.")
            }
        }
        .navigationTitle("녹화 품질")
        .task {
            // Read on appear, never cached at view-construction time — the same
            // staleness bug fixed for the FPS screen in requirement 1.
            currentQuality = RecordingQualitySettingsService().load().selectedQuality
            currentFPS = RecordingFPSSettingsService().load().selectedFPS
        }
    }

    private func presetRow(_ preset: BitratePreset) -> some View {
        Button {
            viewModel.settings.preset = preset
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .foregroundStyle(.primary)
                    Text(preset.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(formattedBitrate(for: preset))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.settings.preset == preset {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    /// The long-form writer's bitrate under `preset`, computed the same way the encoder
    /// will. Built with an explicit in-memory preset rather than the persisted one, so
    /// every row shows its own value instead of the currently-selected one.
    private func formattedBitrate(for preset: BitratePreset) -> String {
        let dimensions = currentQuality.dimensions
        let base = Double(dimensions.width * dimensions.height)
            * Double(currentFPS.rawValue)
            * bitsPerPixel(width: dimensions.width, height: dimensions.height)
        let mbps = base * preset.bitrateMultiplier / 1_000_000
        return String(format: "약 %.0f Mbps", mbps)
    }

    /// Mirrors `BitrateEstimationService`'s tiering. Duplicated here only because that
    /// type applies the persisted preset internally, and this screen needs to preview
    /// all three.
    private func bitsPerPixel(width: Int, height: Int) -> Double {
        switch width * height {
        case ...(1280 * 720): 0.29
        case ...(1920 * 1080): 0.26
        default: 0.20
        }
    }
}

#Preview {
    NavigationStack {
        BitratePresetView()
    }
}
