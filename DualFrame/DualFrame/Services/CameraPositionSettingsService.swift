//
//  CameraPositionSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `CameraPositionSettings` using `UserDefaults`. Mirrors
/// `RecordingQualitySettingsService`.
nonisolated struct CameraPositionSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.cameraPositionSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CameraPositionSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CameraPositionSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: CameraPositionSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
