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
    /// Task 075 item 4: existing installs are migrated to `.fast` once.
    ///
    /// A one-shot flag rather than simply changing the default, because a stored
    /// `.maximum` would otherwise keep overriding it forever — the users who most need
    /// the shorter wait are exactly the ones who already have a value saved. Recorded
    /// separately so a user who *deliberately* picks 최고 품질 after the migration keeps
    /// it; the migration never runs twice.
    private let migrationKey = "com.dualframe.shortGenerationQualityMigratedToFast"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ShortGenerationQualitySettings {
        migrateIfNeeded()
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(ShortGenerationQualitySettings.self, from: data) else {
            return .default
        }
        return settings
    }

    private func migrateIfNeeded() {
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)
        // Only rewrites an existing stored value. A fresh install has nothing saved and
        // simply picks up the new default, so it is left untouched.
        guard defaults.data(forKey: key) != nil else { return }
        save(ShortGenerationQualitySettings(quality: .fast))
    }

    func save(_ settings: ShortGenerationQualitySettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
