//
//  RecordingGuidelineSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `RecordingGuidelineSettings` using `UserDefaults`. Mirrors
/// `RecordingQualitySettingsService`.
nonisolated struct RecordingGuidelineSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.recordingGuidelineSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RecordingGuidelineSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(RecordingGuidelineSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: RecordingGuidelineSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
