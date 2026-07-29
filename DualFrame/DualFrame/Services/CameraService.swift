//
//  CameraService.swift
//  DualFrame
//

import AVFoundation

enum CameraServiceError: Error {
    case deviceUnavailable
    case cannotAddInput
    case cannotAddOutput
    /// Task 027 requirement 3: switching cameras while a recording is in progress is
    /// never allowed — the UI already disables the toggle button while recording, and
    /// this is the defense-in-depth check inside `CameraService` itself.
    case cannotSwitchWhileRecording
}

/// Owns the capture session: camera/microphone inputs for a live preview, plus the
/// video/audio data outputs that feed sample buffers to `RecordingService`.
///
/// `startRunning`/`stopRunning` block the calling thread, so this type is its own actor
/// to keep that work off the main thread.
actor CameraService {
    // AVCaptureSession is safe to run from a background context while a preview layer
    // on the main thread holds the same reference (this mirrors Apple's AVCam sample).
    // Marked `nonisolated(unsafe)` so `CameraPreviewRepresentable` can bind it without awaiting.
    nonisolated(unsafe) let session = AVCaptureSession()

    /// The quality actually in effect after resolving the user's preference against
    /// what the device supports (see `selectFormat(quality:fps:device:)`).
    private(set) var activeQuality: RecordingQuality = .fullHD
    /// True if `activeQuality` differs from the user's selected preference because
    /// the requested quality wasn't supported.
    private(set) var qualityFallbackOccurred = false
    /// The frame rate actually in effect after resolving the user's preference against
    /// what the active format supports (see `selectFormat(quality:fps:device:)`).
    private(set) var activeFPS: RecordingFPS = .fps30
    /// True if `activeFPS` differs from the user's selected preference — either the
    /// rate itself was unsupported, or the resolved recording quality's format
    /// doesn't support it (requirement 8: quality + FPS compatibility).
    private(set) var fpsFallbackOccurred = false

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sampleBufferQueue = DispatchQueue(label: "com.dualframe.camera.sampleBufferQueue")
    private let outputForwarder: SampleBufferOutputForwarder
    private let recordingService: RecordingService
    private let qualitySettingsService: RecordingQualitySettingsService
    private let fpsSettingsService: RecordingFPSSettingsService
    private let positionSettingsService: CameraPositionSettingsService
    /// Task 022: the only source of orientation/mirroring decisions — this type never
    /// computes either itself (requirement 2).
    private let orientationManager: OrientationManager

    private var videoDevice: AVCaptureDevice?
    private var isConfigured = false

    /// The camera currently active, derived from `videoDevice` rather than tracked
    /// separately — there is exactly one source of truth for which device is in use.
    var currentPosition: CameraPosition {
        videoDevice?.position == .front ? .front : .back
    }

    /// `CameraPosition` stays free of AVFoundation (matches `RecordingQuality`'s
    /// pattern) — this is the one place that maps it to `AVCaptureDevice.Position`.
    private func avCapturePosition(for position: CameraPosition) -> AVCaptureDevice.Position {
        switch position {
        case .back: .back
        case .front: .front
        }
    }

    /// `orientationManager` has no default value on purpose — it's `@MainActor`
    /// (see the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` history of
    /// default-parameter isolation errors), so it must be constructed by the caller
    /// and passed in explicitly, same as `CameraPreviewView` already does for every
    /// other shared dependency.
    init(
        recordingService: RecordingService,
        orientationManager: OrientationManager,
        qualitySettingsService: RecordingQualitySettingsService = RecordingQualitySettingsService(),
        fpsSettingsService: RecordingFPSSettingsService = RecordingFPSSettingsService(),
        positionSettingsService: CameraPositionSettingsService = CameraPositionSettingsService()
    ) {
        self.recordingService = recordingService
        self.orientationManager = orientationManager
        self.qualitySettingsService = qualitySettingsService
        self.fpsSettingsService = fpsSettingsService
        self.positionSettingsService = positionSettingsService
        outputForwarder = SampleBufferOutputForwarder(
            recordingService: recordingService,
            performanceMonitor: recordingService.performanceMonitor
        )
    }

    func start() async throws {
        if !isConfigured {
            // Task 039: quality + FPS are now resolved together, directly against
            // device.formats, inside configure()'s call to applyDeviceSpecificSettings
            // — no separate configureFrameRate() step anymore.
            try await configure()
            // RecordingService's AVAssetWriter (and its recovery checkpoint) must
            // reflect the resolution/frame rate the session is actually running at,
            // not just the user's raw preference.
            await recordingService.updateRecordingFormat(quality: activeQuality, fps: activeFPS)
        }
        guard !session.isRunning else { return }
        session.startRunning()
        // Task 029: purely observational — logged after the fact, changes nothing
        // about `startRunning()`'s own behavior (requirement 6: "CameraService 동작"
        // stays exactly as it was).
        logStartupEvent("Session Started")
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    /// Reads the current recording orientation from `OrientationManager` for whichever
    /// camera is active, and pushes the resulting transform to `RecordingService`
    /// (requirement 2: never computed here). Called once per recording, right before
    /// `prepareRecording()` (see `RecordingViewModel.startRecording()`), so a device
    /// rotation between recordings is picked up, while a rotation *during* an active
    /// recording is never read again and so has no effect on it (requirement 5/6).
    func refreshRecordingOrientation() async {
        guard let device = videoDevice else { return }
        let transform = await orientationManager.recordingTransform(for: device.position)
        await recordingService.updateRecordingTransform(transform)
    }

    private func configure() async throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Task 027 requirement 1: no longer hardcoded — reads the user's persisted
        // choice (default `.back`, per `CameraPositionSettings.default`).
        let requestedPosition = positionSettingsService.load().selectedPosition
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avCapturePosition(for: requestedPosition)) else {
            logStartupEvent("Camera Unavailable", detail: requestedPosition.title)
            throw CameraServiceError.deviceUnavailable
        }
        videoDevice = device
        let videoDeviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoDeviceInput) else {
            throw CameraServiceError.cannotAddInput
        }
        session.addInput(videoDeviceInput)

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioDeviceInput) {
            session.addInput(audioDeviceInput)
        } else {
            // Unchanged behavior: audio is still best-effort, never throws — this only
            // adds a visible breadcrumb for why a recording might end up with no audio.
            logStartupEvent("Audio Unavailable")
        }

        videoOutput.setSampleBufferDelegate(outputForwarder, queue: sampleBufferQueue)
        guard session.canAddOutput(videoOutput) else {
            throw CameraServiceError.cannotAddOutput
        }
        session.addOutput(videoOutput)

        audioOutput.setSampleBufferDelegate(outputForwarder, queue: sampleBufferQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        await applyDeviceSpecificSettings(device: device)
        isConfigured = true
        logStartupEvent("Camera Configured", detail: requestedPosition.title)
    }

    /// Task 029: writes to the same shared `RecordingDiagnosticsLogService` instance
    /// `RecordingService` owns, via the `recordingService` reference this type already
    /// holds — no new dependency, and purely observational (requirement 6: doesn't
    /// change what `CameraService` actually does, only records that it happened).
    /// Fire-and-forget, same reasoning as `RecordingService.logEvent`.
    private func logStartupEvent(_ stage: String, detail: String? = nil) {
        let logService = recordingService.diagnosticsLogService
        Task { await logService.log(stage, detail: detail) }
    }

    /// Task 027: resolves quality/FPS/mirroring for whichever `device` is currently
    /// active. Shared by `configure()` (first setup) and `switchCamera(to:)` (a later
    /// camera change), so the two never duplicate this logic.
    ///
    /// Task 039: previously this set `session.sessionPreset` to a resolution-only
    /// preset (e.g. `.hd4K3840x2160`) and then, in a separate step
    /// (`configureFrameRate()`), tried to force a frame rate via
    /// `activeVideoMinFrameDuration`/`activeVideoMaxFrameDuration` against whatever
    /// `AVCaptureDevice.Format` the session preset happened to auto-select. That's the
    /// root cause of "4K selected but recorded as HD" / "60fps selected but recorded
    /// as 30fps": when `sessionPreset != .inputPriority`, AVFoundation — not the app —
    /// owns `activeFormat`, and the specific format it silently picks for a given
    /// preset is not guaranteed to be the one (if any) that supports the requested
    /// frame rate, or even reliably the exact resolution the app assumed. The app was
    /// asking "can the session accept this preset" and "does whatever format the
    /// session already picked support this FPS" — never "does this device actually
    /// have a format matching resolution AND FPS together."
    ///
    /// Fixed by switching to `.inputPriority` (the app owns `activeFormat`) and
    /// directly searching `device.formats` for one whose dimensions and
    /// `videoSupportedFrameRateRanges` both match what the user selected — the actual
    /// device capability list, not a preset abstraction.
    private func applyDeviceSpecificSettings(device: AVCaptureDevice) async {
        let requestedQuality = qualitySettingsService.load().selectedQuality
        let requestedFPS = fpsSettingsService.load().selectedFPS
        let selection = Self.selectFormat(quality: requestedQuality, fps: requestedFPS, device: device)

        session.sessionPreset = .inputPriority
        do {
            try device.lockForConfiguration()
            device.activeFormat = selection.format
            let frameDuration = CMTime(value: 1, timescale: Int32(selection.resolvedFPS.rawValue))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
            activeQuality = selection.resolvedQuality
            qualityFallbackOccurred = selection.qualityFallbackOccurred
            activeFPS = selection.resolvedFPS
            fpsFallbackOccurred = selection.fpsFallbackOccurred
        } catch {
            // lockForConfiguration itself failed (rare — e.g. device just disconnected).
            // Falls back to whatever format the device already has rather than leaving
            // activeQuality/activeFPS out of sync with reality.
            activeQuality = .fullHD
            qualityFallbackOccurred = true
            activeFPS = .fps30
            fpsFallbackOccurred = true
        }

        // Requirement 3/4 (Task 022, now actually exercised for a front camera too):
        // the *recorded* connection must never mirror, regardless of AVFoundation's
        // automatic-mirroring defaults. This only affects the data output feeding
        // `RecordingService` — it doesn't touch the preview layer's own connection (no
        // UI change beyond the toggle button itself).
        if let recordingConnection = videoOutput.connection(with: .video) {
            recordingConnection.automaticallyAdjustsVideoMirroring = false
            recordingConnection.isVideoMirrored = await orientationManager.shouldMirrorRecording(for: device.position)
        }
    }

    /// Task 027 requirement 3: switches the active camera. Only ever safe to call
    /// while nothing is recording — `RecordingService`'s writer(s) are never touched
    /// here (requirement 6: no writer recreation), since this can only run when no
    /// writer exists in the first place.
    func switchCamera(to position: CameraPosition) async throws {
        guard await recordingService.state != .recording else {
            throw CameraServiceError.cannotSwitchWhileRecording
        }
        guard currentPosition != position else { return }

        guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avCapturePosition(for: position)) else {
            throw CameraServiceError.deviceUnavailable
        }
        let newInput = try AVCaptureDeviceInput(device: newDevice)

        guard let currentInput = session.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) }) else {
            throw CameraServiceError.deviceUnavailable
        }

        session.beginConfiguration()
        session.removeInput(currentInput)
        guard session.canAddInput(newInput) else {
            session.addInput(currentInput)
            session.commitConfiguration()
            throw CameraServiceError.cannotAddInput
        }
        session.addInput(newInput)
        session.commitConfiguration()

        videoDevice = newDevice
        await applyDeviceSpecificSettings(device: newDevice)
        // Task 039: the front/back camera can support a different resolution/FPS
        // combination — RecordingService's writer settings must follow whatever
        // applyDeviceSpecificSettings just resolved for the new device, not stay
        // pinned to whatever the previous camera was using.
        await recordingService.updateRecordingFormat(quality: activeQuality, fps: activeFPS)
        positionSettingsService.save(CameraPositionSettings(selectedPosition: position))
    }

    /// Task 039: replaces the old `resolveSessionPreset`/`configureFrameRate` pair.
    /// Searches `device.formats` directly — the actual list of capture formats this
    /// device supports — for one matching `quality`'s pixel dimensions whose
    /// `videoSupportedFrameRateRanges` also covers `fps`. Falls back first to a lower
    /// resolution (same ordering as before: 4K → Full HD → HD), and within whichever
    /// resolution is chosen, falls back to the highest FPS that resolution's matching
    /// formats actually support if `fps` itself isn't available there.
    ///
    /// `nonisolated` — reads no actor state, only queries `device` (an `AVCaptureDevice`
    /// reference, safe to query off-actor). `DeviceCapabilityService` (used by the
    /// Settings screens for requirement 5) applies the same dimension/frame-rate
    /// matching independently, since it has no reason to depend on a live
    /// `CameraService` instance — it only needs a fresh `AVCaptureDevice` reference.
    private nonisolated static func selectFormat(
        quality: RecordingQuality,
        fps: RecordingFPS,
        device: AVCaptureDevice
    ) -> (format: AVCaptureDevice.Format, resolvedQuality: RecordingQuality, resolvedFPS: RecordingFPS, qualityFallbackOccurred: Bool, fpsFallbackOccurred: Bool) {
        let orderedQualities: [RecordingQuality] = [.uhd4K, .fullHD, .hd]
        let startIndex = orderedQualities.firstIndex(of: quality) ?? 0

        for candidateQuality in orderedQualities[startIndex...] {
            let matchingFormats = formats(on: device, matching: candidateQuality)
            guard !matchingFormats.isEmpty else { continue }

            let requestedRate = Double(fps.rawValue)
            if let exactFormat = matchingFormats.first(where: { format in
                format.videoSupportedFrameRateRanges.contains { requestedRate >= $0.minFrameRate && requestedRate <= $0.maxFrameRate }
            }) {
                return (exactFormat, candidateQuality, fps, candidateQuality != quality, false)
            }

            // This resolution exists, but no format at it supports the requested FPS —
            // use whichever matching format supports the highest frame rate instead.
            let bestFormat = matchingFormats.max { a, b in
                (a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                    < (b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            }
            if let bestFormat {
                let maxRate = bestFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? Double(RecordingFPS.fps30.rawValue)
                let fallbackFPS = RecordingFPS.allCases
                    .filter { Double($0.rawValue) <= maxRate }
                    .max(by: { $0.rawValue < $1.rawValue }) ?? .fps30
                return (bestFormat, candidateQuality, fallbackFPS, candidateQuality != quality, true)
            }
        }

        // No candidate resolution matched anything in device.formats — extremely
        // unlikely (every iPhone camera supports at least HD), but fall back to
        // whatever format the device is already using rather than crashing.
        return (device.activeFormat, .hd, .fps30, true, true)
    }

    /// Task 039 requirement 2: the actual query against device capabilities — matches
    /// `AVCaptureDevice.Format.formatDescription`'s pixel dimensions against `quality`,
    /// not a session-preset abstraction.
    private nonisolated static func formats(on device: AVCaptureDevice, matching quality: RecordingQuality) -> [AVCaptureDevice.Format] {
        let target = quality.dimensions
        return device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dimensions.width) == target.width && Int(dimensions.height) == target.height
        }
    }
}

/// Forwards sample buffers from the capture outputs to `RecordingService`.
/// A plain `NSObject` because `AVCapture...SampleBufferDelegate` callbacks arrive
/// synchronously on a dispatch queue, outside of Swift actor isolation.
/// `nonisolated` to opt out of this project's default main-actor isolation — the delegate
/// methods must run on the capture queue, not the main actor.
private nonisolated final class SampleBufferOutputForwarder: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    private let recordingService: RecordingService
    private let performanceMonitor: RecordingPerformanceMonitor

    init(recordingService: RecordingService, performanceMonitor: RecordingPerformanceMonitor) {
        self.recordingService = recordingService
        self.performanceMonitor = performanceMonitor
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let recordingService = recordingService
        let performanceMonitor = performanceMonitor
        if output is AVCaptureVideoDataOutput {
            Task {
                await performanceMonitor.frameSpawned()
                await recordingService.appendVideoSampleBuffer(sampleBuffer)
                await performanceMonitor.frameCompleted()
            }
        } else if output is AVCaptureAudioDataOutput {
            Task {
                await performanceMonitor.frameSpawned()
                await recordingService.appendAudioSampleBuffer(sampleBuffer)
                await performanceMonitor.frameCompleted()
            }
        }
    }

    /// AVFoundation calls this instead of `didOutput` when it has to drop a sample —
    /// e.g. because the pipeline (recording write, in our case) couldn't keep up.
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let performanceMonitor = performanceMonitor
        if output is AVCaptureVideoDataOutput {
            Task { await performanceMonitor.recordDroppedVideoFrame() }
        } else if output is AVCaptureAudioDataOutput {
            Task { await performanceMonitor.recordDroppedAudioBuffer() }
        }
    }
}
