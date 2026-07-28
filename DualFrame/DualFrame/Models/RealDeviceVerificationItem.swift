//
//  RealDeviceVerificationItem.swift
//  DualFrame
//

import Foundation

/// The fixed checklist of features that can only be meaningfully verified on a
/// physical iPhone (Task 031) — Simulator has no camera, so every item here has been
/// exercised only structurally (build success, static UI state) up to this point.
/// `nonisolated` like the project's other pure model enums.
nonisolated enum RealDeviceVerificationItem: String, CaseIterable, Identifiable, Codable {
    case singleRecording
    case dualRecording
    case resume
    case frontCamera
    case backCamera
    case orientation
    case crop
    case recordingGroup
    case photosExport
    case externalStorageExport
    case recovery
    case diagnostics
    case selfTest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleRecording: "Single Recording"
        case .dualRecording: "Dual Recording"
        case .resume: "Resume"
        case .frontCamera: "Front Camera"
        case .backCamera: "Back Camera"
        case .orientation: "Orientation"
        case .crop: "Crop"
        case .recordingGroup: "Recording Group"
        case .photosExport: "Photos Export"
        case .externalStorageExport: "External Storage Export"
        case .recovery: "Recovery"
        case .diagnostics: "Diagnostics"
        case .selfTest: "Self Test"
        }
    }
}
