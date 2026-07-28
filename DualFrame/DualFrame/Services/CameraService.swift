//
//  CameraService.swift
//  DualFrame
//

import AVFoundation

enum CameraServiceError: Error {
    case deviceUnavailable
    case cannotAddInput
    case cannotAddOutput
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

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sampleBufferQueue = DispatchQueue(label: "com.dualframe.camera.sampleBufferQueue")
    private let outputForwarder: SampleBufferOutputForwarder

    private var isConfigured = false

    init(recordingService: RecordingService) {
        outputForwarder = SampleBufferOutputForwarder(recordingService: recordingService)
    }

    func start() throws {
        if !isConfigured {
            try configure()
        }
        guard !session.isRunning else { return }
        session.startRunning()
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraServiceError.deviceUnavailable
        }
        let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
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

        isConfigured = true
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
