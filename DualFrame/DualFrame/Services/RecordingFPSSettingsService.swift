//
//  RecordingFPSSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `RecordingFPSSettings` using `UserDefaults`, which is already
/// thread-safe, so no actor isolation is needed here.
nonisolated struct RecordingFPSSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.recordingFPSSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RecordingFPSSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(RecordingFPSSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: RecordingFPSSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
