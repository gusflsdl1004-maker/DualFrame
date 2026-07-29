//
//  CropBackendSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `CropBackendSettings` in `UserDefaults` — same shape and reasoning as
/// `LateFrameHandlingSettingsService` and `VideoEncoderSettingsService`.
///
/// Read by `RecordingService` when it builds each writer, once per recording, so a
/// change takes effect on the next recording without restarting the session. Also read
/// by `RecordingViewModel` when it writes diagnostics, so a measurement is always
/// stored next to the implementation that produced it.
nonisolated struct CropBackendSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.cropBackendSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CropBackendSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CropBackendSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: CropBackendSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
