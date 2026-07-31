//
//  ShortGenerationQualitySettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `ShortGenerationQualitySettings` — same shape as every other settings
/// service. Read by `ShortGenerationCoordinator` when it builds a job, so a change
/// applies to the next generation.
nonisolated struct ShortGenerationQualitySettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.shortGenerationQualitySettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ShortGenerationQualitySettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(ShortGenerationQualitySettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: ShortGenerationQualitySettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
