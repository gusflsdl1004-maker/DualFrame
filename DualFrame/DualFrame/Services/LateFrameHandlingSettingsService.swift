//
//  LateFrameHandlingSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `LateFrameHandlingSettings` in `UserDefaults`, which is already
/// thread-safe — same shape and reasoning as `RecordingFPSSettingsService`.
///
/// Read by `CameraService` on every `applyFullSizeBufferDelivery()`, which runs before
/// each recording, and by `RecordingViewModel` when it writes the session's
/// diagnostics — so the value stored alongside a measurement is the value that was in
/// force while that measurement was taken.
nonisolated struct LateFrameHandlingSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.lateFrameHandlingSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> LateFrameHandlingSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(LateFrameHandlingSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: LateFrameHandlingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
