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
        case .singleRecording: "단일 녹화"
        case .dualRecording: "듀얼 녹화"
        case .resume: "이어하기"
        case .frontCamera: "전면 카메라"
        case .backCamera: "후면 카메라"
        case .orientation: "화면 방향"
        case .crop: "스마트 크롭"
        case .recordingGroup: "녹화 그룹"
        case .photosExport: "사진 앱 내보내기"
        case .externalStorageExport: "외장 저장소 내보내기"
        case .recovery: "복구"
        case .diagnostics: "진단"
        case .selfTest: "자가 진단"
        }
    }
}
