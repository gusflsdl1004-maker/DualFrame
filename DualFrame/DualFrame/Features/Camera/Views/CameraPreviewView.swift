//
//  CameraPreviewView.swift
//  DualFrame
//

import SwiftUI

/// Shows the live rear-camera preview, or `CameraPermissionDeniedView` when access is denied.
/// Lets the user start/stop recording and shows recording status and elapsed time.
/// No gallery saving happens here.
struct CameraPreviewView: View {
    @StateObject private var permissionViewModel = CameraPermissionViewModel()
    @StateObject private var recordingViewModel: RecordingViewModel
    @State private var cameraService: CameraService

    init() {
        let recordingService = RecordingService()
        _recordingViewModel = StateObject(wrappedValue: RecordingViewModel(service: recordingService))
        _cameraService = State(wrappedValue: CameraService(recordingService: recordingService))
    }

    var body: some View {
        Group {
            if permissionViewModel.isDenied {
                CameraPermissionDeniedView()
            } else {
                CameraPreviewRepresentable(session: cameraService.session)
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        Text(recordingViewModel.statusText)
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.5), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.top, 8)
                    }
                    .overlay(alignment: .bottom) {
                        recordingControls
                    }
            }
        }
        .task {
            await permissionViewModel.requestPermissionsIfNeeded()
            guard permissionViewModel.cameraStatus == .granted,
                  permissionViewModel.microphoneStatus == .granted else { return }
            try? await cameraService.start()
        }
        .onDisappear {
            Task {
                if recordingViewModel.isRecording {
                    await recordingViewModel.stopRecording(expectsAudioTrack: isMicrophoneGranted)
                }
                await cameraService.stop()
            }
        }
    }

    private var isMicrophoneGranted: Bool {
        permissionViewModel.microphoneStatus == .granted
    }

    private var recordingControls: some View {
        VStack(spacing: 8) {
            if let result = recordingViewModel.lastValidationResult {
                VStack(spacing: 2) {
                    Text("Size: \(recordingViewModel.formattedFileSize)")
                    Text("Duration: \(recordingViewModel.formattedRecordedDuration)")
                    Text("Resolution: \(recordingViewModel.formattedResolution)")
                }
                .font(.caption2)
                .foregroundStyle(.white)
                .opacity(result.isValid ? 1 : 0.7)
            } else if let errorMessage = recordingViewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Text(recordingViewModel.formattedDuration)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.white)

            Button {
                recordingViewModel.toggleRecording(expectsAudioTrack: isMicrophoneGranted)
            } label: {
                Text(recordingViewModel.isRecording ? "Stop Recording" : "Start Recording")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(recordingViewModel.isRecording ? Color.red : Color.white, in: Capsule())
                    .foregroundStyle(recordingViewModel.isRecording ? .white : .black)
            }
        }
        .padding(.bottom, 32)
    }
}

#Preview {
    CameraPreviewView()
}
