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

    private var videoDevice: AVCaptureDevice?
    private var isConfigured = false

    init(
        recordingService: RecordingService,
        qualitySettingsService: RecordingQualitySettingsService = RecordingQualitySettingsService(),
        fpsSettingsService: RecordingFPSSettingsService = RecordingFPSSettingsService()
    ) {
        self.recordingService = recordingService
        self.qualitySettingsService = qualitySettingsService
        self.fpsSettingsService = fpsSettingsService
        outputForwarder = SampleBufferOutputForwarder(recordingService: recordingService)
    }

    func start() async throws {
        if !isConfigured {
            try await configure()
            try configureFrameRate()
        }
        guard !session.isRunning else { return }
        session.startRunning()
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    private func configure() async throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraServiceError.deviceUnavailable
        }
        videoDevice = device
        let videoDeviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoDeviceInput) else {
            throw CameraServiceError.cannotAddInput
        }
        session.addInput(videoDeviceInput)

        let requestedQuality = qualitySettingsService.load().selectedQuality
        let resolved = resolveSessionPreset(for: requestedQuality)
        session.sessionPreset = resolved.preset
        activeQuality = resolved.resolvedQuality
        qualityFallbackOccurred = resolved.fallbackOccurred
        // RecordingService's AVAssetWriter must encode at the resolution the session
        // is actually running at, not just the user's raw preference.
        await recordingService.updateVideoDimensions(
            width: resolved.resolvedQuality.dimensions.width,
            height: resolved.resolvedQuality.dimensions.height
        )

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

        isConfigured = true
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

    init(recordingService: RecordingService) {
        self.recordingService = recordingService
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let recordingService = recordingService
        if output is AVCaptureVideoDataOutput {
            Task { await recordingService.appendVideoSampleBuffer(sampleBuffer) }
        } else if output is AVCaptureAudioDataOutput {
            Task { await recordingService.appendAudioSampleBuffer(sampleBuffer) }
        }
    }
}
