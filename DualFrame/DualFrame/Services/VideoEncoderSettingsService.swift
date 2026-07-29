//
//  VideoEncoderSettingsService.swift
//  DualFrame
//

import Foundation

/// Persists `VideoEncoderSettings` in `UserDefaults` — same shape and reasoning as
/// `RecordingFPSSettingsService` and `LateFrameHandlingSettingsService`.
///
/// Read by `RecordingService.makeWriterContext`, which runs once per writer per
/// recording, so a change applies from the next recording onward with no session
/// rebuild. Also read by `RecordingViewModel` when it writes diagnostics, so a
/// measurement is always stored next to the encoder configuration that produced it.
nonisolated struct VideoEncoderSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.videoEncoderSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> VideoEncoderSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(VideoEncoderSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: VideoEncoderSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
