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
    /// Task 042: kept only for the Debug panels (`RecordingDebugView`/
    /// `HealthDashboardView`/`CrashReportExportView`), which still show the internal
    /// Single/Dual concept for diagnostics — never shown anywhere a user sees
    /// (requirement 2). `outputModeViewModel` below is the user-facing replacement.
    @StateObject private var recordingModeViewModel = RecordingModeViewModel()
    /// Task 042: the user-facing "저장 방식" choice (Long만/Short만/Long+Short 저장).
    @StateObject private var outputModeViewModel = RecordingOutputModeViewModel()
    @StateObject private var storageSettingsViewModel = StorageSettingsViewModel()
    @StateObject private var orientationManager = OrientationManager()
    /// Task 040: whether the Long/Short framing guide overlay is shown.
    @StateObject private var guidelineViewModel = RecordingGuidelineViewModel()
    /// Task 041: live storage + estimated recording time.
    @StateObject private var capacityViewModel = RecordingCapacityViewModel()
    @State private var cameraService: CameraService
    @State private var libraryService: InternalVideoLibraryService
    @State private var dualRecordingCoordinator: DualRecordingCoordinator
    @State private var isLibraryPresented = false
    @State private var isSettingsPresented = false
    @State private var isSettingsSummaryPresented = false
    @State private var activeQuality: RecordingQuality?
    @State private var qualityFallbackOccurred = false
    @State private var activeFPS: RecordingFPS?
    @State private var fpsFallbackOccurred = false
    /// Task 043: mirrors `CameraService.zoomOptions`/`min`/`maxZoomFactor` — re-read
    /// once after `cameraService.start()` and again after every successful camera
    /// switch, since the two positions can have different lens configurations.
    @State private var zoomOptions: [CameraZoomOption] = []
    @State private var minZoomFactor: CGFloat = 1.0
    @State private var maxZoomFactor: CGFloat = 1.0
    @State private var currentZoomFactor: CGFloat = 1.0
    /// The zoom factor in effect the moment the current pinch gesture began — pinch
    /// reports a relative scale (1.0 = no change yet), so this is the baseline that
    /// scale multiplies against.
    @State private var zoomFactorAtPinchStart: CGFloat = 1.0
    @GestureState private var pinchScale: CGFloat = 1.0
    /// Task 027: the camera actually in use — reflects `CameraService.currentPosition`,
    /// refreshed after every successful `switchCamera(to:)`.
    @State private var cameraPosition: CameraPosition = .back
    #if DEBUG
    /// Task 026: Real Device Verification Mode entry point — debug builds only, per
    /// this file's `#if DEBUG` guard around every reference to it.
    @State private var isDebugViewPresented = false
    /// Task 030: Automated Self Test entry point — debug builds only.
    @State private var isSelfTestPresented = false
    /// Task 031: Real Device Verification checklist entry point — debug builds only.
    @State private var isVerificationChecklistPresented = false
    /// Task 032: App Health Dashboard entry point — debug builds only.
    @State private var isHealthDashboardPresented = false
    /// Task 035: Crash Report & Log Export entry point — debug builds only.
    @State private var isCrashReportExportPresented = false
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
                    // Task 043 requirement 4: pinch-to-zoom directly on the preview,
                    // matching Apple Camera. `$pinchScale` reports a *relative* scale
                    // (1.0 = unchanged since the gesture began), so it's applied
                    // against `zoomFactorAtPinchStart` — the zoom level the gesture
                    // started from — rather than used as an absolute factor.
                    .gesture(
                        MagnificationGesture()
                            .updating($pinchScale) { value, state, _ in state = value }
                            .onEnded { _ in zoomFactorAtPinchStart = currentZoomFactor }
                    )
                    .onChange(of: pinchScale) { _, newScale in
                        setZoom(zoomFactorAtPinchStart * newScale)
                    }
                    .overlay {
                        // Task 040: purely visual, drawn above the live preview and
                        // below the status bar/controls so it never obscures them.
                        // Camera output itself is untouched — this only draws lines.
                        if guidelineViewModel.settings.isEnabled {
                            RecordingGuidelineOverlayView()
                                .ignoresSafeArea()
                        }
                    }
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
            zoomOptions = await cameraService.zoomOptions
            minZoomFactor = await cameraService.minZoomFactor
            maxZoomFactor = await cameraService.maxZoomFactor
            currentZoomFactor = await cameraService.currentZoomFactor
            zoomFactorAtPinchStart = currentZoomFactor
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
        // Task 041/042: independent 1-second polling loop, same pattern as
        // RecordingDebugView's — re-reads live free space and the currently-active
        // output mode/quality/FPS every second, so both real disk consumption during a
        // recording and any settings change while idle (Long만/Short만/Long+Short 저장
        // included) are reflected within a second. While actively recording, derives
        // the effective output mode from the real underlying RecordingMode the
        // recording actually started with (dualRecordingCoordinator.mode) rather than
        // the live Settings preference, so a mid-recording settings change (which has
        // no effect on the recording already in progress) can't produce a misleading
        // estimate — `.single` → `.longOnly`, `.dual` → `.both` (the two real
        // behaviors `RecordingService` has today; see `RecordingOutputMode`'s docs).
        .task {
            while !Task.isCancelled {
                // Task 043: re-read the actor's real active format every tick instead
                // of relying on the one-time values captured at launch — otherwise this
                // badge (and the capacity estimate below) would keep showing whatever
                // quality/FPS was active when the camera first configured, even after
                // `refreshRecordingFormat()` applies a newly-selected one at the start
                // of the next recording.
                activeQuality = await cameraService.activeQuality
                qualityFallbackOccurred = await cameraService.qualityFallbackOccurred
                activeFPS = await cameraService.activeFPS
                fpsFallbackOccurred = await cameraService.fpsFallbackOccurred

                let effectiveOutputMode: RecordingOutputMode
                if recordingViewModel.isRecording {
                    effectiveOutputMode = await dualRecordingCoordinator.mode == .dual ? .both : .longOnly
                } else {
                    effectiveOutputMode = outputModeViewModel.settings.outputMode
                }
                capacityViewModel.refresh(outputMode: effectiveOutputMode, activeQuality: activeQuality, activeFPS: activeFPS)
                try? await Task.sleep(for: .seconds(1))
            }
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
        .sheet(isPresented: $isSettingsSummaryPresented) {
            RecordingSettingsSummaryView(
                outputModeViewModel: outputModeViewModel,
                storageSettingsViewModel: storageSettingsViewModel,
                orientationManager: orientationManager,
                cameraPosition: cameraPosition,
                activeQuality: activeQuality,
                activeFPS: activeFPS
            )
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
        .sheet(isPresented: $isSelfTestPresented) {
            SelfTestView(libraryService: libraryService, externalStorageViewModel: externalStorageViewModel)
        }
        .sheet(isPresented: $isVerificationChecklistPresented) {
            RealDeviceVerificationChecklistView()
        }
        .sheet(isPresented: $isHealthDashboardPresented) {
            HealthDashboardView(
                permissionViewModel: permissionViewModel,
                recordingViewModel: recordingViewModel,
                recordingModeViewModel: recordingModeViewModel,
                externalStorageViewModel: externalStorageViewModel,
                libraryService: libraryService,
                dualRecordingCoordinator: dualRecordingCoordinator,
                cameraPosition: cameraPosition,
                activeQuality: activeQuality,
                activeFPS: activeFPS
            )
        }
        .sheet(isPresented: $isCrashReportExportPresented) {
            CrashReportExportView(
                recordingViewModel: recordingViewModel,
                recordingModeViewModel: recordingModeViewModel,
                orientationManager: orientationManager,
                permissionViewModel: permissionViewModel,
                externalStorageViewModel: externalStorageViewModel,
                libraryService: libraryService,
                dualRecordingCoordinator: dualRecordingCoordinator,
                cameraPosition: cameraPosition,
                activeQuality: activeQuality,
                activeFPS: activeFPS
            )
        }
        #endif
    }

    /// Task 043 requirement 3/4: the one place that turns a UI gesture/tap into a
    /// `CameraService.setZoomFactor(_:)` call — used by the quick-select buttons, the
    /// slider, and the pinch gesture alike. Updates the local `currentZoomFactor`
    /// immediately (so the slider/buttons/pinch all feel instant) rather than waiting
    /// for the 1-second polling loop to pick up the actor's value.
    private func setZoom(_ factor: CGFloat) {
        currentZoomFactor = min(max(factor, minZoomFactor), maxZoomFactor)
        Task { await cameraService.setZoomFactor(currentZoomFactor) }
    }

    private func isSelectedZoomOption(_ option: CameraZoomOption) -> Bool {
        abs(option.factor - currentZoomFactor) < 0.05
    }

    /// Task 043 requirement 3/4/6: quick-select lens buttons (however many
    /// `zoomOptions` the current device/position actually has) plus a continuous
    /// slider spanning the device's full min–max zoom range, placed bottom-center,
    /// directly above the record button (`recordingControls` below).
    private var zoomControl: some View {
        VStack(spacing: 8) {
            if maxZoomFactor > minZoomFactor {
                Slider(
                    value: Binding(get: { currentZoomFactor }, set: setZoom),
                    in: minZoomFactor...maxZoomFactor
                )
                .frame(width: 220)
                .tint(.white)
            }

            HStack(spacing: 12) {
                ForEach(zoomOptions) { option in
                    Button {
                        setZoom(option.factor)
                    } label: {
                        Text("\(option.label)×")
                            .font(.caption.bold())
                            .foregroundStyle(isSelectedZoomOption(option) ? .black : .white)
                            .frame(width: 34, height: 34)
                            .background(
                                isSelectedZoomOption(option) ? Color.white : Color.black.opacity(0.35),
                                in: Circle()
                            )
                    }
                }
            }
        }
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
            // Task 043: the camera just switched can have an entirely different lens
            // configuration (the front camera typically has no ultra-wide/telephoto).
            zoomOptions = await cameraService.zoomOptions
            minZoomFactor = await cameraService.minZoomFactor
            maxZoomFactor = await cameraService.maxZoomFactor
            currentZoomFactor = await cameraService.currentZoomFactor
            zoomFactorAtPinchStart = currentZoomFactor
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
                        // Task 038 requirement 2: shows the readable quality tier
                        // (e.g. "Full HD (1080p)") instead of raw pixel dimensions —
                        // simpler at a glance, same underlying value.
                        Text(activeQuality.title)
                    }
                    if let activeFPS {
                        Text(activeFPS.title)
                    }
                    // Task 042 requirement 1: the main camera screen now shows the
                    // user-facing output mode, never "Single Recording"/"Dual Recording".
                    Text(outputModeViewModel.settings.outputMode.title)
                }
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
                .foregroundStyle(.white)

                Spacer()

                // Task 038 requirement 2: icon buttons enlarged (10 → 14 padding) for
                // easier tapping, matching the Camera app's touch-target sizing.
                Button {
                    isLibraryPresented = true
                } label: {
                    Image(systemName: "film")
                        .padding(14)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }

                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                        .padding(14)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }

                Button {
                    isSettingsSummaryPresented = true
                } label: {
                    Image(systemName: "info.circle")
                        .padding(14)
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
                        .padding(14)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(recordingViewModel.isRecording)

                #if DEBUG
                // Task 032: as the number of debug-only tools grew, a fixed row of
                // standalone icons stopped scaling. Consolidated into one menu —
                // still debug-only, still just entry points into existing read-only
                // tools, no new behavior.
                Menu {
                    Button {
                        isDebugViewPresented = true
                    } label: {
                        Label("녹화 디버그", systemImage: "ladybug")
                    }
                    Button {
                        isSelfTestPresented = true
                    } label: {
                        Label("자가 진단", systemImage: "checkmark.shield")
                    }
                    Button {
                        isVerificationChecklistPresented = true
                    } label: {
                        Label("실기기 점검 목록", systemImage: "checklist")
                    }
                    Button {
                        isHealthDashboardPresented = true
                    } label: {
                        Label("상태 대시보드", systemImage: "heart.text.square")
                    }
                    Button {
                        isCrashReportExportPresented = true
                    } label: {
                        Label("진단 로그 내보내기", systemImage: "doc.badge.arrow.up")
                    }
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .padding(14)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }
                #endif
            }

            capacityBadge

            if qualityFallbackOccurred, let activeQuality {
                Text("이 기기에서 지원하지 않는 화질이라 \(activeQuality.title)(으)로 대신 녹화합니다.")
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.yellow)
            }

            if fpsFallbackOccurred, let activeFPS {
                Text("현재 화질에서 지원하지 않는 프레임레이트라 \(activeFPS.title)(으)로 대신 녹화합니다.")
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

            // Task 041 requirement 5: recording would fail outright — a clearer,
            // upfront message rather than only surfacing this after a failed attempt.
            if capacityViewModel.isStorageInsufficientToRecord {
                Text("저장 공간이 부족하여 녹화를 시작할 수 없습니다.")
                    .font(.caption2.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.red)
            }

            interruptionBanner
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Task 041: "남은 저장 공간 / 예상 촬영 가능" — updated every second by the
    /// polling `.task` above, independent of the recording pipeline.
    private var capacityBadge: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("남은 저장 공간")
                Text(capacityViewModel.formattedAvailableSpace).bold()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("예상 촬영 가능")
                Text(capacityViewModel.formattedEstimatedTime).bold().monospacedDigit()
            }
        }
        .font(.caption2)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
        .foregroundStyle(capacityWarningColor)
    }

    /// Requirement 4: 5분 이하 → 노란색, 1분 이하 → 빨간색.
    private var capacityWarningColor: Color {
        switch capacityViewModel.warningLevel {
        case .normal: .white
        case .low: .yellow
        case .critical: .red
        }
    }

    @ViewBuilder
    private var interruptionBanner: some View {
        switch recordingViewModel.interruptionStatus {
        case .none:
            EmptyView()
        case .interrupted(let source):
            VStack(spacing: 6) {
                Text("녹화 일시정지됨 — \(source.title)")
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.orange)
                resumeButton
            }
        case .ended:
            VStack(spacing: 6) {
                Text("중단 상황이 끝났습니다 — 녹화는 계속 일시정지 상태입니다.")
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
            Text(AppStrings.Camera.resumeRecording)
                .font(.caption.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
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
                    Text("롱폼: \(longFormStatusText)")
                }
                if let shortFormStatusText = recordingViewModel.shortFormStatusText {
                    Text("숏폼: \(shortFormStatusText)")
                }
            }
            .font(.caption2.bold())
            .foregroundStyle(.white)
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 10) {
            if let result = recordingViewModel.lastValidationResult {
                VStack(spacing: 2) {
                    Text("용량 \(recordingViewModel.formattedFileSize)")
                    Text("길이 \(recordingViewModel.formattedRecordedDuration)")
                    Text("해상도 \(recordingViewModel.formattedResolution)")
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
                .font(.title2.monospacedDigit().bold())
                .foregroundStyle(.white)

            dualRecordingStatusRows

            #if DEBUG
            // Task 038 requirement 4: frame-drop/memory/write-latency figures are
            // developer diagnostics, not something an end user needs mid-recording —
            // moved behind #if DEBUG instead of always showing on the main screen.
            // The underlying stats are unchanged; only where they're displayed moved.
            if recordingViewModel.isRecording {
                HStack(spacing: 12) {
                    Text("Dropped: \(recordingViewModel.formattedDroppedFrames)")
                    Text("Mem: \(recordingViewModel.memoryStatusText)")
                    Text("Write: \(recordingViewModel.writeStatusText)")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
            }
            #endif

            // Task 043 requirement 6: bottom-center, directly above the record button.
            zoomControl

            // Task 038 requirement 2: enlarged (bigger font, more padding) so the
            // primary action reads clearly at a glance, closer to the Camera app's
            // prominent shutter control.
            Button {
                recordingViewModel.toggleRecording(expectsAudioTrack: isMicrophoneGranted)
            } label: {
                Text(recordingViewModel.isRecording ? AppStrings.Camera.stopRecording : AppStrings.Camera.startRecording)
                    .font(.title3.bold())
                    .padding(.horizontal, 36)
                    .padding(.vertical, 18)
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
