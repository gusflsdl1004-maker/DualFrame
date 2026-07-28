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

            Text("카메라 권한이 필요합니다")
                .font(.title2.bold())

            Text("영상을 녹화하려면 카메라와 마이크 접근 권한이 필요합니다. 설정에서 권한을 허용해 주세요.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("설정으로 이동") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }
}

#Preview {
    CameraPermissionDeniedView()
}
