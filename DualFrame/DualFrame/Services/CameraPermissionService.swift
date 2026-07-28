//
//  CameraPermissionService.swift
//  DualFrame
//

import AVFoundation

/// The authorization state for a single hardware permission (camera or microphone).
enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied
}

/// Checks and requests camera/microphone authorization.
/// This only wraps `AVCaptureDevice` authorization APIs — no `AVCaptureSession` is created here.
protocol CameraPermissionServicing {
    func cameraStatus() -> PermissionStatus
    func microphoneStatus() -> PermissionStatus
    func requestCameraAccess() async -> PermissionStatus
    func requestMicrophoneAccess() async -> PermissionStatus
}

struct CameraPermissionService: CameraPermissionServicing {
    func cameraStatus() -> PermissionStatus {
        AVCaptureDevice.authorizationStatus(for: .video).asPermissionStatus
    }

    func microphoneStatus() -> PermissionStatus {
        AVCaptureDevice.authorizationStatus(for: .audio).asPermissionStatus
    }

    func requestCameraAccess() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .granted : .denied
    }

    func requestMicrophoneAccess() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }
}

private extension AVAuthorizationStatus {
    var asPermissionStatus: PermissionStatus {
        switch self {
        case .authorized:
            .granted
        case .notDetermined:
            .notDetermined
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }
}
