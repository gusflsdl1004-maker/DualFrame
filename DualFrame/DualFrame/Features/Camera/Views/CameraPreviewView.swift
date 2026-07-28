//
//  CameraPreviewView.swift
//  DualFrame
//

import SwiftUI

/// Shows the live rear-camera preview, or `CameraPermissionDeniedView` when access is denied.
/// No recording, photo capture, or saving happens here — preview only.
/// Displays the current recording status; there is no recording button yet.
struct CameraPreviewView: View {
    @StateObject private var permissionViewModel = CameraPermissionViewModel()
    @StateObject private var recordingViewModel = RecordingViewModel()
    @State private var cameraService = CameraService()

    var body: some View {
        Group {
            if permissionViewModel.isDenied {
                CameraPermissionDeniedView()
            } else {
                CameraPreviewRepresentable(session: cameraService.session)
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        Text(recordingViewModel.statusText)
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.5), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.top, 8)
                    }
            }
        }
        .task {
            await permissionViewModel.requestPermissionsIfNeeded()
            guard permissionViewModel.cameraStatus == .granted else { return }
            try? await cameraService.start()
        }
        .onDisappear {
            Task { await cameraService.stop() }
        }
    }
}

#Preview {
    CameraPreviewView()
}
