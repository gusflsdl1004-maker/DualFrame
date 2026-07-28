//
//  StorageSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `StorageSettings` using `UserDefaults`, which is already thread-safe,
/// so no actor isolation is needed here.
nonisolated struct StorageSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.storageSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> StorageSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(StorageSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: StorageSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
