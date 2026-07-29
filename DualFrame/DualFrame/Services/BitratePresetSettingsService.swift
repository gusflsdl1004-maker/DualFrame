//
//  BitratePresetSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `BitratePresetSettings` using `UserDefaults`. Mirrors
/// `RecordingQualitySettingsService`.
nonisolated struct BitratePresetSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.bitratePresetSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> BitratePresetSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(BitratePresetSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: BitratePresetSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
