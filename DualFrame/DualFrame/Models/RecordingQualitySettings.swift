//
//  RecordingQualitySettings.swift
//  DualFrame
//

import Foundation

/// The user's persisted recording resolution preference.
nonisolated struct RecordingQualitySettings: Codable, Equatable {
    var selectedQuality: RecordingQuality

    static let `default` = RecordingQualitySettings(selectedQuality: .fullHD)
}
