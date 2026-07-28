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
    @StateObject private var interruptionMonitor = RecordingInterruptionMonitor()
    @StateObject private var recordingModeViewModel = RecordingModeViewModel()
    @StateObject private var orientationManager = OrientationManager()
    @State private var cameraService: CameraService
    @State private var libraryService: InternalVideoLibraryService
    @State private var dualRecordingCoordinator: DualRecordingCoordinator
    @State private var isLibraryPresented = false
    @State private var isSettingsPresented = false
    @State private var activeQuality: RecordingQuality?
    @State private var qualityFallbackOccurred = false
    @State private var activeFPS: RecordingFPS?
    @State private var fpsFallbackOccurred = false
    /// Task 027: the camera actually in use — reflects `CameraService.currentPosition`,
    /// refreshed after every successful `switchCamera(to:)`.
    @State private var cameraPosition: CameraPosition = .back
    #if DEBUG
    /// Task 026: Real Device Verification Mode entry point — debug builds only, per
    /// this file's `#if DEBUG` guard around every reference to it.
    @State private var isDebugViewPresented = false
    #endif

    init() {
        let libraryService = InternalVideoLibraryService()
        let recordingService = RecordingService(libraryService: libraryService)
        let coordinator = DualRecordingCoordinator(
            mode: RecordingModeSettingsService().load().mode,
            recordingService: recordingService
        )
        let orientationManager = OrientationManager()
        let cameraService = CameraService(recordingService: recordingService, orientationManager: orientationManager)
        _recordingViewModel = StateObject(wrappedValue: RecordingViewModel(
            service: recordingService,
            dualRecordingCoordinator: coordinator,
            cameraService: cameraService,
            libraryService: libraryService
        ))
        _cameraService = State(wrappedValue: cameraService)
        _libraryService = State(wrappedValue: libraryService)
        _dualRecordingCoordinator = State(wrappedValue: coordinator)
        _orientationManager = StateObject(wrappedValue: orientationManager)
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
            orientationManager.startObserving()
            await permissionViewModel.requestPermissionsIfNeeded()
            guard permissionViewModel.cameraStatus == .granted,
                  permissionViewModel.microphoneStatus == .granted else { return }
            try? await cameraService.start()
            activeQuality = await cameraService.activeQuality
            qualityFallbackOccurred = await cameraService.qualityFallbackOccurred
            activeFPS = await cameraService.activeFPS
            fpsFallbackOccurred = await cameraService.fpsFallbackOccurred
            cameraPosition = await cameraService.currentPosition
            interruptionMonitor.startObserving(
                session: cameraService.session,
                onInterruptionBegan: { source in
                    await recordingViewModel.handleInterruptionBegan(source)
                },
                onInterruptionEnded: {
                    recordingViewModel.handleInterruptionEnded()
                }
            )
        }
        .onDisappear {
            interruptionMonitor.stopObserving()
            orientationManager.stopObserving()
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
        #if DEBUG
        .sheet(isPresented: $isDebugViewPresented) {
            RecordingDebugView(
                recordingViewModel: recordingViewModel,
                orientationManager: orientationManager,
                recordingModeViewModel: recordingModeViewModel,
                activeQuality: activeQuality,
                activeFPS: activeFPS,
                dualRecordingCoordinator: dualRecordingCoordinator
            )
        }
        #endif
    }

    private var isMicrophoneGranted: Bool {
        permissionViewModel.microphoneStatus == .granted
    }

    /// Task 027 requirement 3: a no-op while recording (the button is also disabled,
    /// this is the view-layer half of the defense-in-depth — `CameraService` itself
    /// refuses the switch too). Re-reads `activeQuality`/`activeFPS`/`fpsFallbackOccurred`
    /// afterward since a different camera can resolve them differently.
    private func toggleCameraPosition() async {
        guard !recordingViewModel.isRecording else { return }
        let nextPosition: CameraPosition = cameraPosition == .back ? .front : .back
        do {
            try await cameraService.switchCamera(to: nextPosition)
            cameraPosition = await cameraService.currentPosition
            activeQuality = await cameraService.activeQuality
            qualityFallbackOccurred = await cameraService.qualityFallbackOccurred
            activeFPS = await cameraService.activeFPS
            fpsFallbackOccurred = await cameraService.fpsFallbackOccurred
        } catch {
            // Switching failed (e.g. no front camera on this device) — stay on the
            // current camera rather than leaving the UI in an inconsistent state.
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Text(recordingViewModel.displayStatusText)
                    if let activeQuality {
                        Text("\(activeQuality.dimensions.width)×\(activeQuality.dimensions.height)")
                    }
                    if let activeFPS {
                        Text(activeFPS.title)
                    }
                    Text(recordingModeViewModel.settings.mode.title)
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

                // Task 027 requirement 3: disabled while recording — switching camera
                // mid-recording is never allowed, both here and defensively inside
                // `CameraService.switchCamera(to:)` itself.
                Button {
                    Task { await toggleCameraPosition() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(recordingViewModel.isRecording)

                #if DEBUG
                Button {
                    isDebugViewPresented = true
                } label: {
                    Image(systemName: "ladybug")
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }
                #endif
            }

            if qualityFallbackOccurred, let activeQuality {
                Text("Requested quality isn't supported on this device — using \(activeQuality.title) instead.")
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.yellow)
            }

            if fpsFallbackOccurred, let activeFPS {
                Text("Requested frame rate isn't supported at this quality — using \(activeFPS.title) instead.")
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.yellow)
            }

            if let lowStorageWarning = recordingViewModel.lowStorageWarning {
                Text(lowStorageWarning)
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.yellow)
            }

            interruptionBanner
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var interruptionBanner: some View {
        switch recordingViewModel.interruptionStatus {
        case .none:
            EmptyView()
        case .interrupted(let source):
            VStack(spacing: 6) {
                Text("Recording paused — \(source.title)")
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.orange)
                resumeButton
            }
        case .ended:
            VStack(spacing: 6) {
                Text("Interruption ended — recording is still paused.")
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.orange)
                resumeButton
            }
        }
    }

    /// Requirement 1: only ever shown while paused, and only ever acts when the user
    /// taps it — nothing resumes a recording automatically.
    private var resumeButton: some View {
        Button {
            Task { await recordingViewModel.resumeRecording() }
        } label: {
            Text("Resume Recording")
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white, in: Capsule())
                .foregroundStyle(.black)
        }
    }

    /// Long/Short Recording status, shown independently (requirement 8) — only
    /// populated while `RecordingMode` is `.dual`, so this renders nothing in `.single`
    /// mode (unchanged from before Task 019).
    @ViewBuilder
    private var dualRecordingStatusRows: some View {
        if recordingViewModel.longFormStatusText != nil || recordingViewModel.shortFormStatusText != nil {
            VStack(spacing: 2) {
                if let longFormStatusText = recordingViewModel.longFormStatusText {
                    Text("Long Recording: \(longFormStatusText)")
                }
                if let shortFormStatusText = recordingViewModel.shortFormStatusText {
                    Text("Short Recording: \(shortFormStatusText)")
                }
            }
            .font(.caption2.bold())
            .foregroundStyle(.white)
        }
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

            dualRecordingStatusRows

            if recordingViewModel.isRecording {
                HStack(spacing: 12) {
                    Text("Dropped: \(recordingViewModel.formattedDroppedFrames)")
                    Text("Mem: \(recordingViewModel.memoryStatusText)")
                    Text("Write: \(recordingViewModel.writeStatusText)")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
            }

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
