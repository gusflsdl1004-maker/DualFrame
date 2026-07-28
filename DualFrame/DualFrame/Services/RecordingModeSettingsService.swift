//
//  RecordingModeSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `RecordingModeSettings` using `UserDefaults`. Mirrors
/// `RecordingQualitySettingsService`.
nonisolated struct RecordingModeSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.recordingModeSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RecordingModeSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(RecordingModeSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: RecordingModeSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
