//
//  StorageDestinationView.swift
//  DualFrame
//

import SwiftUI

/// The app's settings screen. Edits and persists preferences only — it never runs export
/// or recording logic itself.
///
/// Task 087 (P1-1): **the four things people actually change are on this screen, not
/// behind it.**
///
/// 화질, FPS, 저장 방식 and 코덱 were four separate push destinations (and 코덱 was not
/// here at all — it was a Task 064 experiment buried in 진단). Choosing a recording setup
/// meant four round trips and no way to see the combination you had ended up with. They
/// are now inline pickers in one section, with the resulting configuration stated above
/// them, so the whole decision is visible at once.
///
/// Everything that is *not* one of those four moved down or out of the way: storage
/// destination and its options stay but sit below recording, and the remaining
/// drill-downs (외장 저장소, 녹화 품질, 복구, 진단) are collected under 고급 where they no
/// longer compete with the common case.
/// Task 090 P0: **every settings view model is handed in, not created here.**
///
/// These were `@StateObject`s owned by this screen. Each one was therefore a *second*
/// instance over the same `UserDefaults` key, and the camera screen's copy — loaded once
/// in its `init` — never learned that this one had saved. The guide toggle did nothing
/// visible, and quality/FPS only appeared to take effect when the next recording re-read
/// the store directly. One instance per setting, owned by `CameraPreviewView`, fixes both.
struct StorageDestinationView: View {
    @StateObject private var recoveryViewModel = RecoveryViewModel(checkpointStore: RecordingCheckpointStore())
    /// Task 087: the codec is a recording setting, so it belongs with the others. Local
    /// `@State` written straight back to the store, matching how 진단 held it —
    /// `RecordingService` re-reads the store when it builds each writer, so a change here
    /// applies from the next recording.
    @State private var encoderSettings = VideoEncoderSettingsService().load()
    private let encoderSettingsService = VideoEncoderSettingsService()
    @ObservedObject var externalStorageViewModel: ExternalStorageViewModel
    @ObservedObject var storageSettingsViewModel: StorageSettingsViewModel
    @ObservedObject var guidelineViewModel: RecordingGuidelineViewModel
    @ObservedObject var qualityViewModel: RecordingQualityViewModel
    @ObservedObject var fpsViewModel: RecordingFPSViewModel
    @ObservedObject var outputModeViewModel: RecordingOutputModeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // The combination, stated once. Each picker below changes one term of
                    // it, and this is the only place the result of all four is legible —
                    // "4K · 60fps · HEVC" is the thing being chosen, not four settings.
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summaryLine)
                            .font(.headline)
                        Text(outputModeViewModel.settings.outputMode.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("현재 설정")
                }

                Section {
                    Picker("화질", selection: $qualityViewModel.settings.selectedQuality) {
                        ForEach(RecordingQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    Picker("프레임", selection: $fpsViewModel.settings.selectedFPS) {
                        ForEach(RecordingFPS.allCases) { fps in
                            Text(fps.title).tag(fps)
                        }
                    }
                    Picker("저장 방식", selection: $outputModeViewModel.settings.outputMode) {
                        ForEach(RecordingOutputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker("코덱", selection: $encoderSettings.codec) {
                        ForEach(VideoCodecPreference.allCases) { codec in
                            Text(codec.title).tag(codec)
                        }
                    }
                    Text(encoderSettings.codec.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("녹화")
                } footer: {
                    Text("화질과 프레임은 촬영 화면에 즉시 적용됩니다(녹화 중에는 다음 녹화부터). 기기가 고른 조합을 지원하지 않으면 가장 가까운 설정으로 자동 조정되며, 촬영 화면에 실제 적용된 값이 표시됩니다. 코덱은 다음 녹화부터 적용됩니다.")
                }

                Section {
                    Toggle("구도 가이드 표시", isOn: $guidelineViewModel.settings.isEnabled)
                } footer: {
                    Text("촬영 화면을 가로선 두 개로 3등분해 수평선·눈높이를 잡기 쉽게 합니다. 저장되는 영상에는 나타나지 않습니다.")
                }

                Section("기본 저장 위치") {
                    ForEach(StorageDestination.allCases) { destination in
                        destinationRow(destination)
                    }
                }

                Section {
                    Toggle("매번 물어보기", isOn: $storageSettingsViewModel.settings.askEveryTime)
                    Toggle("내부 보관함에도 보관", isOn: $storageSettingsViewModel.settings.keepInternalCopy)
                }

                Section("고급") {
                    NavigationLink("녹화 품질 (비트레이트)") {
                        BitratePresetView()
                    }
                    NavigationLink("외장 저장소 관리") {
                        ExternalStorageView(viewModel: externalStorageViewModel)
                    }
                    NavigationLink("녹화 세션 기록") {
                        DiagnosticsView()
                    }
                }

                Section("복구") {
                    recoveryStatusView
                }
            }
            .navigationTitle("설정")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .onChange(of: encoderSettings) { _, newValue in
            encoderSettingsService.save(newValue)
        }
        .task {
            await recoveryViewModel.checkRecoveryStatus()
        }
    }

    /// e.g. `4K (2160p) · 60 FPS · HEVC 고정`. Reads the stored preference, not the
    /// resolved one — this screen is where the request is made, and the camera screen's
    /// HUD is where what the device actually did is reported.
    private var summaryLine: String {
        [
            qualityViewModel.settings.selectedQuality.title,
            fpsViewModel.settings.selectedFPS.title,
            encoderSettings.codec.title
        ].joined(separator: " · ")
    }

    @ViewBuilder
    private var recoveryStatusView: some View {
        switch recoveryViewModel.status {
        case .checking:
            Text("확인 중...")
                .foregroundStyle(.secondary)

        case .noRecoveryNeeded:
            Text("복구할 항목 없음")
                .foregroundStyle(.secondary)

        case .recoveryAvailable:
            VStack(alignment: .leading, spacing: 4) {
                Text("복구 가능한 녹화가 있습니다")
                    .font(.headline)
                Text("마지막 녹화: \(recoveryViewModel.formattedTimestamp)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("길이: \(recoveryViewModel.formattedDuration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(recoveryViewModel.temporaryFileExists ? "파일 있음" : "파일 없음")
                    .font(.caption)
                    .foregroundStyle(recoveryViewModel.temporaryFileExists ? .green : .red)
            }

        case .corrupted:
            Text("복구 데이터가 손상되었습니다")
                .foregroundStyle(.red)
        }
    }

    private func destinationRow(_ destination: StorageDestination) -> some View {
        let available = isAvailable(destination)
        return Button {
            storageSettingsViewModel.settings.defaultDestination = destination
        } label: {
            HStack {
                Text(destination.title)
                    .foregroundStyle(available ? .primary : .secondary)
                if !available {
                    Text("(사용 불가)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if storageSettingsViewModel.settings.defaultDestination == destination {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(!available)
    }

    /// `externalDrive` is only selectable once a location has been connected via
    /// "Manage External Storage" — every other destination is always available.
    private func isAvailable(_ destination: StorageDestination) -> Bool {
        guard destination == .externalDrive else { return true }
        return externalStorageViewModel.device != nil
    }
}

#Preview {
    StorageDestinationView(
        externalStorageViewModel: ExternalStorageViewModel(),
        storageSettingsViewModel: StorageSettingsViewModel(),
        guidelineViewModel: RecordingGuidelineViewModel(),
        qualityViewModel: RecordingQualityViewModel(),
        fpsViewModel: RecordingFPSViewModel(),
        outputModeViewModel: RecordingOutputModeViewModel()
    )
}
