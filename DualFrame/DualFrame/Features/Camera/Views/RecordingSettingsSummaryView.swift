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
    @ObservedObject var recordingModeViewModel: RecordingModeViewModel
    @ObservedObject var storageSettingsViewModel: StorageSettingsViewModel
    @ObservedObject var orientationManager: OrientationManager
    let cameraPosition: CameraPosition
    let activeQuality: RecordingQuality?
    let activeFPS: RecordingFPS?

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    LabeledContent("Camera", value: cameraPosition.title)
                    LabeledContent("Orientation", value: orientationLabel)
                }

                Section("Recording") {
                    LabeledContent("Recording Mode", value: recordingModeViewModel.settings.mode.title)
                    LabeledContent("Recording Group Mode", value: recordingModeViewModel.settings.mode.title)
                    LabeledContent("Recording Quality", value: activeQuality?.title ?? "--")
                    LabeledContent(
                        "Resolution",
                        value: activeQuality.map { "\($0.dimensions.width)×\($0.dimensions.height)" } ?? "--"
                    )
                    LabeledContent("FPS", value: activeFPS?.title ?? "--")
                }

                Section("Storage") {
                    LabeledContent("Storage Destination", value: storageSettingsViewModel.settings.defaultDestination.title)
                    LabeledContent("Keep Internal Copy", value: storageSettingsViewModel.settings.keepInternalCopy ? "On" : "Off")
                }
            }
            .navigationTitle("Recording Summary")
        }
    }

    private var orientationLabel: String {
        switch orientationManager.deviceOrientation {
        case .portrait: "Portrait"
        case .portraitUpsideDown: "Portrait Upside Down"
        case .landscapeLeft: "Landscape Left"
        case .landscapeRight: "Landscape Right"
        }
    }
}
