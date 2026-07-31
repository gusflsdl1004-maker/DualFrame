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
    /// Task 050: the quality preset shown in the HUD.
    @StateObject private var bitratePresetViewModel = BitratePresetViewModel()
    @State private var cameraService: CameraService
    @State private var libraryService: InternalVideoLibraryService
    @State private var dualRecordingCoordinator: DualRecordingCoordinator
    @State private var isLibraryPresented = false
    /// Task 072 P0-5: guards the generation-cancel button behind a confirmation.
    @State private var isConfirmingGenerationCancel = false
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
    /// Task 050 requirement 7: the raw factor the user reads as "1×". Needed to show a
    /// meaningful zoom value on a virtual multi-lens device, where `videoZoomFactor`
    /// 1.0 is the ultra-wide (a "0.5×" view) rather than the wide lens.
    @State private var baseZoomFactor: CGFloat = 1.0
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

    /// Task 070: owned by `ContentView`, not here — generation has to outlive this
    /// screen (requirement 3).
    @ObservedObject private var shortGenerationCoordinator: ShortGenerationCoordinator

    init(
        libraryService: InternalVideoLibraryService,
        shortGenerationCoordinator: ShortGenerationCoordinator
    ) {
        self.shortGenerationCoordinator = shortGenerationCoordinator
        let recordingService = RecordingService(libraryService: libraryService)
        let coordinator = DualRecordingCoordinator(
            mode: RecordingModeSettingsService().load().mode,
            recordingService: recordingService
        )
        let orientationManager = OrientationManager()
        let cameraService = CameraService(recordingService: recordingService, orientationManager: orientationManager)
        let viewModel = RecordingViewModel(
            service: recordingService,
            dualRecordingCoordinator: coordinator,
            cameraService: cameraService,
            libraryService: libraryService
        )
        viewModel.shortGenerationCoordinator = shortGenerationCoordinator
        _recordingViewModel = StateObject(wrappedValue: viewModel)
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
                // Task 047 requirement 3: one GeometryReader drives the whole
                // responsive layout. `isLandscape` is derived from the actual
                // container size rather than from `OrientationManager` — the recording
                // pipeline's orientation is a separate concern (CLAUDE.md rules 52-56)
                // and must never be coupled to how the UI happens to be laid out.
                GeometryReader { geometry in
                    let isLandscape = geometry.size.width > geometry.size.height
                    // A ZStack, not `.overlay` on the preview: the preview calls
                    // `.ignoresSafeArea()`, which expands it *past* the GeometryReader's
                    // bounds, and anything overlaid on it inherits that oversized frame
                    // — which pushed the status chips off the left edge. Layering here
                    // instead keeps every control inside the safe area while the camera
                    // image alone still bleeds edge to edge.
                    ZStack {
                        // Task 075 (UI 개편) P0-1: both outputs as real previews.
                        // Portrait + Long&Short only — in landscape the two panes would
                        // each be a letterboxed sliver, and on Long-only there is no
                        // second result to show, so both fall back to the full-screen
                        // preview this app has always had.
                        Group {
                            if !isLandscape, outputModeViewModel.settings.outputMode == .both {
                                DualPreviewStack(
                                    session: cameraService.session,
                                    showsShortPane: true
                                )
                            } else {
                                CameraPreviewRepresentable(session: cameraService.session)
                                    .ignoresSafeArea()
                            }
                        }
                            // Task 043 requirement 4: pinch-to-zoom directly on the
                            // preview, matching Apple Camera. `$pinchScale` reports a
                            // *relative* scale (1.0 = unchanged since the gesture
                            // began), so it's applied against `zoomFactorAtPinchStart`
                            // — the zoom level the gesture started from — rather than
                            // used as an absolute factor.
                            .gesture(
                                MagnificationGesture()
                                    .updating($pinchScale) { value, state, _ in state = value }
                                    .onEnded { _ in zoomFactorAtPinchStart = currentZoomFactor }
                            )
                            .onChange(of: pinchScale) { _, newScale in
                                setZoom(zoomFactorAtPinchStart * newScale)
                            }

                        // Task 040: purely visual, drawn above the live preview and
                        // below the status bar/controls so it never obscures them.
                        // Camera output itself is untouched — this only draws lines.
                        // Superseded by `DualPreviewStack` whenever it is shown — a dim
                        // mask over a full-screen preview answers the same question the
                        // stacked panes now answer directly, and drawing both would be
                        // two competing depictions of one crop.
                        if guidelineViewModel.settings.isEnabled,
                           isLandscape || outputModeViewModel.settings.outputMode != .both {
                            RecordingGuidelineOverlayView()
                                .ignoresSafeArea()
                        }

                        // Task 076 P0-1: the live short-form result, beside the
                        // long-form one. Only shown when a short-form output is
                        // actually going to be produced — on Long-only it would be
                        // promising a file that never arrives.
                        //
                        // A second preview layer on the same session: display-side
                        // only, no data output and no writer, so it cannot cost capture
                        // throughput the way the second *writer* did before Task 069.
                        // Landscape keeps the PIP: the stacked layout needs vertical
                        // room it does not have there, but the short-form result still
                        // has to be visible while composing.
                        if guidelineViewModel.settings.isEnabled,
                           isLandscape,
                           outputModeViewModel.settings.outputMode == .both {
                            VStack {
                                HStack {
                                    Spacer()
                                    ShortPreviewPIP(session: cameraService.session)
                                        .padding(.trailing, 12)
                                }
                                Spacer()
                            }
                            .padding(.top, 12)
                        }

                        // Task 052 requirement 3: two genuinely different layouts, not
                        // one layout rotated. Portrait keeps the familiar
                        // top-bar/bottom-controls split; landscape uses dedicated
                        // leading/trailing columns so nothing sits over the middle of
                        // the frame — which is where the subject is, and where the
                        // 16:9/9:16 framing guides overlap.
                        if isLandscape {
                            landscapeOverlay
                        } else {
                            portraitOverlay
                        }
                    }
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
            baseZoomFactor = await cameraService.baseZoomFactor
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
        // Task 069: shown once recording has stopped and the long-form file is already
        // saved, while the short-form output is derived from it. An overlay rather than
        // a sheet so the camera stays visible behind it.
        .overlay {
            ShortGenerationOverlay(
                state: shortGenerationCoordinator.state,
                quality: shortGenerationCoordinator.activeQuality,
                // Task 072 P0-5: confirm first. Cancelling discards work the user has
                // already waited minutes for, and the banner's 취소 sits next to a
                // progress bar where a mis-tap is easy.
                onCancel: { isConfirmingGenerationCancel = true },
                onRetry: { shortGenerationCoordinator.retry() },
                onDismiss: { shortGenerationCoordinator.dismissResult() }
            )
        }
        // Task 074: tapping the completion notification opens the library. The
        // coordinator only publishes the id; navigation stays a view concern.
        .onChange(of: shortGenerationCoordinator.pendingNavigationGroupID) { _, groupID in
            guard groupID != nil else { return }
            isLibraryPresented = true
            shortGenerationCoordinator.pendingNavigationGroupID = nil
        }
        .alert("쇼츠 생성을 취소하시겠습니까?", isPresented: $isConfirmingGenerationCancel) {
            Button("계속 생성", role: .cancel) {}
            Button("취소하기", role: .destructive) { shortGenerationCoordinator.cancel() }
        } message: {
            Text("지금까지 생성된 내용은 삭제됩니다. 원본 Long 영상은 삭제되지 않습니다.")
        }
        .sheet(isPresented: $isLibraryPresented) {
            VideoLibraryView(
                libraryService: libraryService,
                externalStorageViewModel: externalStorageViewModel,
                shortGenerationCoordinator: shortGenerationCoordinator
            )
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

    /// Task 045 requirement 3: the one place that turns a UI gesture/tap into a
    /// `CameraService.setZoomFactor(_:animated:)` call — used by the quick-select
    /// buttons, the slider, and the pinch gesture alike. Updates the local
    /// `currentZoomFactor` immediately (so all three feel instant) rather than waiting
    /// for the 1-second polling loop to pick up the actor's value.
    ///
    /// `animated` is only ever true for a discrete lens-button tap; continuous input
    /// (slider drag, pinch) must not ramp — see `CameraService.setZoomFactor`.
    private func setZoom(_ factor: CGFloat, animated: Bool = false) {
        currentZoomFactor = min(max(factor, minZoomFactor), maxZoomFactor)
        let target = currentZoomFactor
        Task { await cameraService.setZoomFactor(target, animated: animated) }
    }

    private func isSelectedZoomOption(_ option: CameraZoomOption) -> Bool {
        abs(option.factor - currentZoomFactor) < 0.05
    }

    /// Task 043 requirement 3/4/6: quick-select lens buttons (however many
    /// `zoomOptions` the current device/position actually has) plus a continuous
    /// slider spanning the device's full min–max zoom range, placed bottom-center,
    /// directly above the record button (`recordingControls` below).
    /// Task 050 requirement 7: the live zoom value, normalised so the user reads what
    /// they expect — "1.0×" for the wide lens even when the underlying
    /// `videoZoomFactor` is 2.0 on a virtual multi-lens device. Updated by the buttons,
    /// the slider and pinch alike, since all three funnel through `setZoom`.
    private var currentZoomLabel: String {
        let displayed = baseZoomFactor > 0 ? currentZoomFactor / baseZoomFactor : currentZoomFactor
        return String(format: "%.1f×", displayed)
    }

    private func zoomControl(isLandscape: Bool) -> some View {
        VStack(spacing: 8) {
            // Requirement 7: always visible, so pinch has a readout too — the discrete
            // buttons alone can't show an intermediate value.
            Text(currentZoomLabel)
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.45), in: Capsule())

            if maxZoomFactor > minZoomFactor {
                Slider(
                    value: Binding(
                        get: { currentZoomFactor },
                        // Continuous drag — never ramped (see `setZoom`).
                        set: { setZoom($0, animated: false) }
                    ),
                    in: minZoomFactor...maxZoomFactor
                )
                // Task 047: narrower in the landscape trailing column so it can't
                // overflow it.
                .frame(width: isLandscape ? 170 : 220)
                .tint(.white)
            }

            // Task 076 #2: the always-visible row is replaced by a collapsed circular
            // control. The row's width grew with the device's lens count and it held
            // that space permanently — on a screen now carrying two live previews, the
            // zoom UI should cost nothing until it is used.
            FloatingZoomControl(
                options: zoomOptions,
                currentFactor: currentZoomFactor,
                baseFactor: baseZoomFactor,
                // Requirement 3 (Task 043): discrete stop → smooth ramp, unchanged.
                onSelect: { option in setZoom(option.factor, animated: true) }
            )
            HStack(spacing: 12) {
                EmptyView()
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
            baseZoomFactor = await cameraService.baseZoomFactor
            zoomFactorAtPinchStart = currentZoomFactor
        } catch {
            // Switching failed (e.g. no front camera on this device) — stay on the
            // current camera rather than leaving the UI in an inconsistent state.
        }
    }

    /// Task 045 requirement 4: one status label. `lineLimit(1)` plus
    /// `fixedSize(horizontal: true, ...)` is what actually prevents the Korean
    /// mid-word wrapping — it tells SwiftUI to give the label its full intrinsic
    /// width rather than compressing it until the text has to break between
    /// characters.
    /// Task 047 requirement 3: a full-sentence warning, as opposed to `statusChip`'s
    /// short label. These were plain `Text` in a Capsule with no width bound, so a long
    /// Korean sentence either ran past the screen edge or — since Korean offers no
    /// spaces to break on — wrapped between characters. A rounded rectangle (a Capsule
    /// clips multi-line text badly), an explicit multi-line allowance, and a width
    /// ceiling tied to the container make it wrap as readable lines instead.
    private func warningBanner(_ text: String, color: Color = .yellow) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(color)
            .frame(maxWidth: 320, alignment: .leading)
    }

    private func statusChip(_ text: String, emphasized: Bool = false) -> some View {
        Text(text)
            .font(.caption.bold())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                emphasized ? Color.red.opacity(0.85) : Color.black.opacity(0.5),
                in: Capsule()
            )
            .foregroundStyle(.white)
    }

    private func statusBar(isLandscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Task 047 requirement 3: the icon row gets its own full-width row rather
            // than competing with the status chips for one line. Five 46pt targets plus
            // the debug menu need ~230pt; alongside the chip column that exceeded a
            // 393pt-wide screen, clipping the camera-toggle and pushing the debug menu
            // off-screen entirely. Stacking them removes the competition, so neither
            // side has to shrink at any screen size.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                iconButtons
            }

            HStack(alignment: .top) {
                // Task 045 requirement 4: previously one long HStack of four Texts in
                // a single Capsule. In portrait that row is wider than the screen, and
                // because each label is Korean, SwiftUI wrapped it *inside* words
                // ("준비 완/료") — Korean has no spaces to break on, so the only break
                // opportunity is between characters. Split into independently-sized
                // capsules laid out by a wrapping HStack, each pinned to one line, so
                // a label either fits whole or moves to the next row — never splits.
                VStack(alignment: .leading, spacing: 4) {
                    if let statusText = recordingViewModel.visibleStatusText {
                        statusChip(statusText, emphasized: true)
                    }
                    recordingHUD
                }
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            statusDetails
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Portrait: HUD and entry points along the top, controls along the bottom — the
    /// full width is available, so nothing has to compete for the middle.
    private var portraitOverlay: some View {
        ZStack {
            statusBar(isLandscape: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            recordingControls(isLandscape: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// Task 052 requirement 3: a layout built for landscape rather than inherited from
    /// portrait.
    ///
    /// In landscape the frame is wide and short: a top bar plus a bottom bar would eat
    /// most of the vertical space and sit directly over the subject. So the two edges
    /// that are *cheap* in landscape are used instead —
    ///   leading  : HUD and warnings, top-aligned
    ///   trailing : entry-point icons above, record control below
    /// — leaving the entire horizontal centre band, where both framing guides sit,
    /// completely unobstructed.
    private var landscapeOverlay: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if let statusText = recordingViewModel.visibleStatusText {
                    statusChip(statusText, emphasized: true)
                }
                recordingHUD
                statusDetails
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 8) { iconButtons }
                Spacer(minLength: 0)
                recordingControls(isLandscape: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Task 047 requirement 3: the top-right entry points, extracted so the status bar
    /// can lay them out on their own row instead of squeezing them beside the status
    /// chips.
    @ViewBuilder
    private var iconButtons: some View {
        Group {
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
    }

    /// Task 047 requirement 3: capacity readout, fallback notices and the interruption
    /// banner. Split out of `statusBar` so each block is width-bounded on its own and a
    /// long Korean sentence can wrap without disturbing the rows above it.
    /// Task 050 requirement 2: the recording HUD — the settings that will apply to the
    /// next recording, in two short lines.
    ///
    ///     4K (2160p) | 60 FPS | 고화질
    ///     약 6시간 12분
    ///
    /// Deliberately limited to quality, frame rate, quality preset and remaining time
    /// (requirement 2). Long/Short output mode, dropped frames, writer status and every
    /// other diagnostic stay out of it — output mode is still visible in the 녹화 요약
    /// sheet, and the diagnostics remain Debug-only (requirement 8).
    private var recordingHUD: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hudSettingsLine)
                .font(.caption.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(hudRemainingLine)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .foregroundStyle(capacityWarningColor)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
    }

    /// "4K (2160p) | 60 FPS | 고화질". Falls back to placeholders until the camera has
    /// resolved its actual format, so the line never collapses or jumps in width.
    private var hudSettingsLine: String {
        [
            activeQuality?.title ?? "--",
            activeFPS?.title ?? "--",
            bitratePresetViewModel.settings.preset.shortTitle
        ].joined(separator: "  |  ")
    }

    private var hudRemainingLine: String {
        "약 \(capacityViewModel.approximateRemainingText) 촬영 가능"
    }

    @ViewBuilder
    private var statusDetails: some View {
        if qualityFallbackOccurred, let activeQuality {
            warningBanner("이 기기에서 지원하지 않는 화질이라 \(activeQuality.title)(으)로 대신 녹화합니다.")
        }

        if fpsFallbackOccurred, let activeFPS {
            warningBanner("현재 화질에서 지원하지 않는 프레임레이트라 \(activeFPS.title)(으)로 대신 녹화합니다.")
        }

        if let lowStorageWarning = recordingViewModel.lowStorageWarning {
            warningBanner(lowStorageWarning)
        }

        // Task 041 requirement 5: recording would fail outright — a clearer,
        // upfront message rather than only surfacing this after a failed attempt.
        if capacityViewModel.isStorageInsufficientToRecord {
            warningBanner("저장 공간이 부족하여 녹화를 시작할 수 없습니다.", color: .red)
        }

        interruptionBanner
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

    /// Task 051 requirement 6: the "녹화 이어하기" button is gone. The banner now only
    /// *informs* — it tells the user the recording paused and why, and that stopping
    /// will save what was captured so far.
    ///
    /// Removing resume does not risk footage: an interrupted recording stays paused
    /// with its writers intact, and Stop still finalises and validates everything
    /// captured up to the interruption (CLAUDE.md priority 1). What is lost is only the
    /// ability to append *more* to that same file after a phone call.
    @ViewBuilder
    private var interruptionBanner: some View {
        switch recordingViewModel.interruptionStatus {
        case .none:
            EmptyView()
        case .interrupted(let source):
            warningBanner("녹화 일시정지됨 — \(source.title). 정지하면 지금까지 촬영된 영상이 저장됩니다.", color: .orange)
        case .ended:
            warningBanner("중단 상황이 끝났습니다. 정지하면 지금까지 촬영된 영상이 저장됩니다.", color: .orange)
        }
    }

    /// Per-writer Long/Short status.
    ///
    /// Task 050 requirement 8: now Debug-only. This was still rendering on the Release
    /// camera screen, which requirement 8 explicitly rules out ("Long 저장 / Short 저장
    /// … Debug 빌드에서만"). A source-level audit of what remains outside `#if DEBUG`
    /// is what caught it — the `strings` check could not, because it does not extract
    /// these Korean literals from either binary.
    ///
    /// Only populated while `RecordingMode` is `.dual`, so it rendered nothing in
    /// `.single` mode even before this (unchanged from Task 019).
    @ViewBuilder
    private var dualRecordingStatusRows: some View {
        #if DEBUG
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
        #endif
    }

    /// Task 047 requirement 3: the same controls, laid out for the space available.
    /// Portrait keeps the familiar bottom-centre stack; landscape moves them to a
    /// narrower trailing column, because a wide bottom stack on a short screen
    /// overlapped both the status bar and the framing guide. Everything inside is
    /// width-bounded so nothing is clipped on a small device.
    private func recordingControls(isLandscape: Bool) -> some View {
        VStack(spacing: isLandscape ? 8 : 10) {
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
                // Requirement 3: error text is a full sentence — allow it to wrap
                // rather than run off the edge.
                Text(errorMessage)
                    .font(.caption2)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
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
            //
            // Task 047: in landscape these three side by side are wider than the
            // trailing column, so they stack there instead of being clipped.
            if recordingViewModel.isRecording {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text("Dropped: \(recordingViewModel.formattedDroppedFrames)")
                        Text("Mem: \(recordingViewModel.memoryStatusText)")
                        Text("Write: \(recordingViewModel.writeStatusText)")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dropped: \(recordingViewModel.formattedDroppedFrames)")
                        Text("Mem: \(recordingViewModel.memoryStatusText)")
                        Text("Write: \(recordingViewModel.writeStatusText)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
            }
            #endif

            // Task 043 requirement 6 / 047: directly above the record button in both
            // orientations — the control itself adapts its own width.
            zoomControl(isLandscape: isLandscape)

            // Task 038 requirement 2: enlarged (bigger font, more padding) so the
            // primary action reads clearly at a glance, closer to the Camera app's
            // prominent shutter control. Task 047: slightly tighter in landscape so
            // the whole column fits a short screen without clipping.
            Button {
                recordingViewModel.toggleRecording(expectsAudioTrack: isMicrophoneGranted)
            } label: {
                Text(recordingViewModel.isRecording ? AppStrings.Camera.stopRecording : AppStrings.Camera.startRecording)
                    .font(isLandscape ? .body.bold() : .title3.bold())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, isLandscape ? 24 : 36)
                    .padding(.vertical, isLandscape ? 12 : 18)
                    .background(recordingViewModel.isRecording ? Color.red : Color.white, in: Capsule())
                    .foregroundStyle(recordingViewModel.isRecording ? .white : .black)
            }
        }
        // Requirement 3: Safe Area respected in both orientations — the trailing
        // column clears the home indicator/notch side, the bottom stack clears the
        // home indicator.
        .padding(isLandscape ? .trailing : .bottom, isLandscape ? 20 : 32)
        .padding(isLandscape ? .vertical : .horizontal, 12)
        .frame(maxWidth: isLandscape ? 260 : .infinity)
    }
}

#Preview {
    let libraryService = InternalVideoLibraryService()
    return CameraPreviewView(
        libraryService: libraryService,
        shortGenerationCoordinator: ShortGenerationCoordinator(libraryService: libraryService)
    )
}
