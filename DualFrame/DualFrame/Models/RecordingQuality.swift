//
//  RecordingQuality.swift
//  DualFrame
//

import Foundation

/// A selectable recording resolution. Kept free of AVFoundation — the mapping to an
/// `AVCaptureSession.Preset` lives in `CameraService`, which is the layer that
/// actually knows about capture hardware.
nonisolated enum RecordingQuality: String, CaseIterable, Identifiable, Codable {
    case hd
    case fullHD
    case uhd4K

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hd: "HD (720p)"
        case .fullHD: "Full HD (1080p)"
        case .uhd4K: "4K (2160p)"
        }
    }

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .hd: (1280, 720)
        case .fullHD: (1920, 1080)
        case .uhd4K: (3840, 2160)
        }
    }
}
