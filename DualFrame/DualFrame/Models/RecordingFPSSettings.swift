//
//  RecordingFPSSettings.swift
//  DualFrame
//

import Foundation

/// The user's persisted recording frame rate preference.
nonisolated struct RecordingFPSSettings: Codable, Equatable {
    var selectedFPS: RecordingFPS

    static let `default` = RecordingFPSSettings(selectedFPS: .fps30)
}
