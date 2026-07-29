//
//  RecordingSettingsSummaryView.swift
//  DualFrame
//

import SwiftUI

/// A read-only summary of the settings that will apply to the *next* recording,
/// shown before the user taps Start Recording (Task 028). Every value here comes
/// from an existing ViewModel or already-resolved `CameraPreviewView` state — this
/// view adds no new business logic and cannot change anything (no controls, only
/// `LabeledContent`). Available in both Debug and Release builds.
struct RecordingSettingsSummaryView: View {
    @ObservedObject var outputModeViewModel: RecordingOutputModeViewModel
    @ObservedObject var storageSettingsViewModel: StorageSettingsViewModel
    @ObservedObject var orientationManager: OrientationManager
    let cameraPosition: CameraPosition
    let activeQuality: RecordingQuality?
    let activeFPS: RecordingFPS?

    var body: some View {
        NavigationStack {
            Form {
                Section("카메라") {
                    LabeledContent("카메라", value: cameraPosition.title)
                    LabeledContent("방향", value: AppStrings.orientationLabel(orientationManager.deviceOrientation))
                }

                Section("녹화") {
                    // Task 042 requirement 5: shows the user-facing output mode, never
                    // the internal Single/Dual RecordingMode concept.
                    LabeledContent("저장 방식", value: outputModeViewModel.settings.outputMode.title)
                    LabeledContent("화질", value: activeQuality?.title ?? "--")
                    LabeledContent("FPS", value: activeFPS?.title ?? "--")
                }

                Section("저장") {
                    LabeledContent("저장 위치", value: storageSettingsViewModel.settings.defaultDestination.title)
                    LabeledContent("내부 보관함에도 보관", value: storageSettingsViewModel.settings.keepInternalCopy ? "켬" : "끔")
                }
            }
            .navigationTitle("녹화 요약")
        }
    }
}
