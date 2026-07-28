//
//  CameraPreviewView.swift
//  DualFrame
//

import SwiftUI

/// Shows the live rear-camera preview, or `CameraPermissionDeniedView` when access is denied.
/// Lets the user start/stop recording, shows recording status and elapsed time, and
/// opens the internal video library. No gallery saving happens here.
struct CameraPreviewView: View {
    @StateObject private var permissionViewModel = CameraPermissionViewModel()
    @StateObject private var recordingViewModel: RecordingViewModel
    @StateObject private var externalStorageViewModel = ExternalStorageViewModel()
    @State private var cameraService: CameraService
    @State private var libraryService: InternalVideoLibraryService
    @State private var isLibraryPresented = false
    @State private var isSettingsPresented = false
    @State private var activeQuality: RecordingQuality?
    @State private var qualityFallbackOccurred = false

    init() {
        let libraryService = InternalVideoLibraryService()
        let recordingService = RecordingService(libraryService: libraryService)
        _recordingViewModel = StateObject(wrappedValue: RecordingViewModel(service: recordingService))
        _cameraService = State(wrappedValue: CameraService(recordingService: recordingService))
        _libraryService = State(wrappedValue: libraryService)
    }

    var body: some View {
        Group {
            if permissionViewModel.isDenied {
                CameraPermissionDeniedView()
            } else {
                CameraPreviewRepresentable(session: cameraService.session)
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        statusBar
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
            activeQuality = await cameraService.activeQuality
            qualityFallbackOccurred = await cameraService.qualityFallbackOccurred
        }
        .onDisappear {
            Task {
                if recordingViewModel.isRecording {
                    await recordingViewModel.stopRecording(expectsAudioTrack: isMicrophoneGranted)
                }
                await cameraService.stop()
            }
        }
        .sheet(isPresented: $isLibraryPresented) {
            VideoLibraryView(libraryService: libraryService, externalStorageViewModel: externalStorageViewModel)
        }
        .sheet(isPresented: $isSettingsPresented) {
            StorageDestinationView(externalStorageViewModel: externalStorageViewModel)
        }
    }

    private var isMicrophoneGranted: Bool {
        permissionViewModel.microphoneStatus == .granted
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Text(recordingViewModel.statusText)
                    if let activeQuality {
                        Text("\(activeQuality.dimensions.width)×\(activeQuality.dimensions.height)")
                    }
                }
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
                .foregroundStyle(.white)

                Spacer()

                Button {
                    isLibraryPresented = true
                } label: {
                    Image(systemName: "film")
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }

                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }
            }

            if qualityFallbackOccurred, let activeQuality {
                Text("Requested quality isn't supported on this device — using \(activeQuality.title) instead.")
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
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
