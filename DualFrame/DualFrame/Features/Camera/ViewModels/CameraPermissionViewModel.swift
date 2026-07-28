//
//  CameraPermissionViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Tracks camera and microphone authorization state for the Camera feature.
@MainActor
final class CameraPermissionViewModel: ObservableObject {
    @Published private(set) var cameraStatus: PermissionStatus
    @Published private(set) var microphoneStatus: PermissionStatus

    private let service: CameraPermissionServicing

    var isAuthorized: Bool {
        cameraStatus == .granted && microphoneStatus == .granted
    }

    var isDenied: Bool {
        cameraStatus == .denied || microphoneStatus == .denied
    }

    init(service: CameraPermissionServicing = CameraPermissionService()) {
        self.service = service
        cameraStatus = service.cameraStatus()
        microphoneStatus = service.microphoneStatus()
    }

    func requestPermissionsIfNeeded() async {
        if cameraStatus == .notDetermined {
            cameraStatus = await service.requestCameraAccess()
        }
        if microphoneStatus == .notDetermined {
            microphoneStatus = await service.requestMicrophoneAccess()
        }
    }
}
