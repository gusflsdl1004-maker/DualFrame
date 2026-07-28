//
//  CameraPositionSettings.swift
//  DualFrame
//

import Foundation

/// The user's persisted camera position preference. Mirrors `RecordingQualitySettings`.
nonisolated struct CameraPositionSettings: Codable, Equatable {
    var selectedPosition: CameraPosition

    static let `default` = CameraPositionSettings(selectedPosition: .back)
}
