//
//  CameraPosition.swift
//  DualFrame
//

import Foundation

/// Which physical camera is active. Kept free of AVFoundation — the mapping to
/// `AVCaptureDevice.Position` lives in `CameraService`, which is the layer that
/// actually knows about capture hardware (matches `RecordingQuality`'s pattern).
nonisolated enum CameraPosition: String, CaseIterable, Identifiable, Codable {
    case back
    case front

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: "후면 카메라"
        case .front: "전면 카메라"
        }
    }
}
