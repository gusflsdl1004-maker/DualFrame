//
//  RecordingOutputModeSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `RecordingOutputModeSettings` using `UserDefaults`. Mirrors
/// `RecordingModeSettingsService`. A deliberately separate key/store from
/// `RecordingModeSettingsService` — `RecordingOutputModeViewModel` is what keeps the
/// two in sync (requirement 2: `RecordingMode` stays internal-only).
nonisolated struct RecordingOutputModeSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.recordingOutputModeSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a value has ever been saved under this key — distinct from `load()`
    /// returning `.default`, which also happens when nothing has ever been saved
    /// *or* when a previously-saved value no longer decodes (e.g. the removed
    /// `.shortOnly` case). `RecordingOutputModeViewModel` uses this to decide whether
    /// to migrate from the legacy `RecordingMode` instead of silently applying
    /// `.default`.
    var hasStoredValue: Bool {
        defaults.data(forKey: key) != nil
    }

    func load() -> RecordingOutputModeSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(RecordingOutputModeSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: RecordingOutputModeSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
