//
//  RecordingFPS.swift
//  DualFrame
//

import Foundation

/// A selectable recording frame rate. Kept free of AVFoundation — checking device
/// support and configuring `AVCaptureDevice` lives in `CameraService`.
nonisolated enum RecordingFPS: Int, CaseIterable, Identifiable, Codable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var title: String {
        "\(rawValue) FPS"
    }
}
