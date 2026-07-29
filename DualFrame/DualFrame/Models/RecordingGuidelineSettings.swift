//
//  RecordingGuidelineSettings.swift
//  DualFrame
//

import Foundation

/// The user's persisted preference for whether the Long/Short framing guide overlay
/// (Task 040) is shown on the camera preview. Mirrors `RecordingQualitySettings`.
nonisolated struct RecordingGuidelineSettings: Codable, Equatable {
    var isEnabled: Bool

    /// Requirement 5: on by default.
    static let `default` = RecordingGuidelineSettings(isEnabled: true)
}
