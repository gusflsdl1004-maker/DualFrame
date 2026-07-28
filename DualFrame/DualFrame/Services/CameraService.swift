//
//  CameraService.swift
//  DualFrame
//

import AVFoundation

enum CameraServiceError: Error {
    case deviceUnavailable
    case cannotAddInput
    case cannotAddOutput
    case cannotConfigureFrameRate
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
    /// what the device supports (see `resolveSessionPreset`).
    private(set) var activeQuality: RecordingQuality = .fullHD
    /// True if `activeQuality` differs from the user's selected preference because
    /// the requested quality wasn't supported.
    private(set) var qualityFallbackOccurred = false
    /// The frame rate actually in effect after resolving the user's preference against
    /// what the active format supports (see `resolveFrameRate`).
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
            try await configure()
            try configureFrameRate()
            // RecordingService's AVAssetWriter (and its recovery checkpoint) must
            // reflect the resolution/frame rate the session is actually running at,
            // not just the user's raw preference.
            await recordingService.updateRecordingFormat(quality: activeQuality, fps: activeFPS)
        }
        guard !session.isRunning else { return }
        session.startRunning()
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
    }

    /// Task 027: resolves quality/mirroring for whichever `device` is currently
    /// active. Shared by `configure()` (first setup) and `switchCamera(to:)` (a later
    /// camera change), so the two never duplicate this logic.
    private func applyDeviceSpecificSettings(device: AVCaptureDevice) async {
        let requestedQuality = qualitySettingsService.load().selectedQuality
        let resolved = resolveSessionPreset(for: requestedQuality)
        session.sessionPreset = resolved.preset
        activeQuality = resolved.resolvedQuality
        qualityFallbackOccurred = resolved.fallbackOccurred

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
        try configureFrameRate()
        positionSettingsService.save(CameraPositionSettings(selectedPosition: position))
    }

    /// Tries `quality`'s preset first, then degrades toward lower resolutions until
    /// one the session reports as supported is found. `canSetSessionPreset` is checked
    /// after the video input is added, since support depends on the connected camera.
    private func resolveSessionPreset(
        for quality: RecordingQuality
    ) -> (preset: AVCaptureSession.Preset, resolvedQuality: RecordingQuality, fallbackOccurred: Bool) {
        let orderedQualities: [RecordingQuality] = [.uhd4K, .fullHD, .hd]
        guard let startIndex = orderedQualities.firstIndex(of: quality) else {
            return (.high, .fullHD, true)
        }

        for candidate in orderedQualities[startIndex...] {
            let preset = sessionPreset(for: candidate)
            if session.canSetSessionPreset(preset) {
                return (preset, candidate, candidate != quality)
            }
        }
        return (.high, quality, true)
    }

    private func sessionPreset(for quality: RecordingQuality) -> AVCaptureSession.Preset {
        switch quality {
        case .hd: .hd1280x720
        case .fullHD: .hd1920x1080
        case .uhd4K: .hd4K3840x2160
        }
    }

    /// Sets the device's active frame rate to match the user's preference, falling
    /// back to the highest rate the *current* active format supports. Must run after
    /// `configure()` has committed the session preset — the preset determines which
    /// `AVCaptureDevice.Format` (and therefore which frame rate ranges) is active, so
    /// this is naturally where quality + FPS compatibility (requirement 8) is resolved.
    private func configureFrameRate() throws {
        guard let device = videoDevice else { return }

        let requestedFPS = fpsSettingsService.load().selectedFPS
        let resolved = resolveFrameRate(for: requestedFPS, format: device.activeFormat)
        activeFPS = resolved.resolvedFPS
        fpsFallbackOccurred = resolved.fallbackOccurred

        guard let frameDuration = resolved.frameDuration else { return }

        do {
            try device.lockForConfiguration()
        } catch {
            throw CameraServiceError.cannotConfigureFrameRate
        }
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
    }

    /// Finds the highest frame rate supported by `format` that's no greater than
    /// `fps`'s requested rate; if `fps` itself is supported, uses it as-is.
    private func resolveFrameRate(
        for fps: RecordingFPS,
        format: AVCaptureDevice.Format
    ) -> (frameDuration: CMTime?, resolvedFPS: RecordingFPS, fallbackOccurred: Bool) {
        let ranges = format.videoSupportedFrameRateRanges
        let requestedRate = Double(fps.rawValue)

        if ranges.contains(where: { requestedRate >= $0.minFrameRate && requestedRate <= $0.maxFrameRate }) {
            return (CMTime(value: 1, timescale: Int32(fps.rawValue)), fps, false)
        }

        guard let highestSupportedRate = ranges.map(\.maxFrameRate).max() else {
            return (nil, fps, true)
        }

        let fallbackFPS = RecordingFPS.allCases
            .filter { Double($0.rawValue) <= highestSupportedRate }
            .max(by: { $0.rawValue < $1.rawValue }) ?? .fps30

        return (CMTime(value: 1, timescale: Int32(fallbackFPS.rawValue)), fallbackFPS, true)
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
