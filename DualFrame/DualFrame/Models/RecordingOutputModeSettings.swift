//
//  RecordingOutputModeSettings.swift
//  DualFrame
//

import Foundation

/// The user's persisted output-mode preference. Mirrors `RecordingModeSettings`.
nonisolated struct RecordingOutputModeSettings: Codable, Equatable {
    var outputMode: RecordingOutputMode

    /// Requirement: 기본값은 Long + Short.
    static let `default` = RecordingOutputModeSettings(outputMode: .both)
}
