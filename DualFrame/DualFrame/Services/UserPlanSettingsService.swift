//
//  UserPlanSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists the user's plan — same shape as every other settings service here.
///
/// Task 071: this is a **local placeholder for an entitlement**, not an entitlement.
/// A real Pro flag has to come from StoreKit and be verified; a `UserDefaults` boolean
/// is trivially flipped. It exists so the export flow can be built and exercised now,
/// and so the one place that reads the plan (`ExportManager`) is already correct when
/// the receipt check replaces this.
nonisolated struct UserPlanSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.userPlanSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> UserPlanSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(UserPlanSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: UserPlanSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
