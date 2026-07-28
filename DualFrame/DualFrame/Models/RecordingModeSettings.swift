//
//  RecordingModeSettings.swift
//  DualFrame
//

import Foundation

/// The user's persisted recording mode preference. Mirrors `RecordingQualitySettings`.
nonisolated struct RecordingModeSettings: Codable, Equatable {
    var mode: RecordingMode

    static let `default` = RecordingModeSettings(mode: .single)
}
