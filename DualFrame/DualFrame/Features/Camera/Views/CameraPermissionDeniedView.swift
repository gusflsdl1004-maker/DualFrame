//
//  CameraPermissionDeniedView.swift
//  DualFrame
//

import SwiftUI

/// Shown in place of the camera screen when camera or microphone access has been denied.
struct CameraPermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Camera Access Required")
                .font(.title2.bold())

            Text("DualFrame needs camera and microphone access to record video. Please enable access in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#Preview {
    CameraPermissionDeniedView()
}
