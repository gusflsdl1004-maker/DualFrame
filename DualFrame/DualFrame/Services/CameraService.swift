//
//  CameraService.swift
//  DualFrame
//

import AVFoundation

enum CameraServiceError: Error {
    case deviceUnavailable
    case cannotAddInput
}

/// Owns the capture session for a live preview only.
/// No `AVCaptureOutput` (photo/movie) is attached — this cannot record or capture photos.
///
/// `startRunning`/`stopRunning` block the calling thread, so this type is its own actor
/// to keep that work off the main thread.
actor CameraService {
    // AVCaptureSession is safe to run from a background context while a preview layer
    // on the main thread holds the same reference (this mirrors Apple's AVCam sample).
    // Marked `nonisolated(unsafe)` so `CameraPreviewRepresentable` can bind it without awaiting.
    nonisolated(unsafe) let session = AVCaptureSession()

    private var isConfigured = false

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

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraServiceError.deviceUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraServiceError.cannotAddInput
        }
        session.addInput(input)

        isConfigured = true
    }
}
