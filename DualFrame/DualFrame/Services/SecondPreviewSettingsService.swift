//
//  SecondPreviewSettingsService.swift
//  DualFrame
//

import Foundation

/// Whether the short-form preview layer is attached to the capture session.
///
/// Task 077: this exists as a **switch** because the measurement that motivates it is
/// an A/B, and this project has been burned once by hardcoding one side of an untested
/// hypothesis — Task 055 pinned `alwaysDiscardsLateVideoFrames` to one value and every
/// measurement for the next eight tasks was taken on that side, so no comparison existed
/// at all. A toggle plus a record of which side produced each run is what makes the
/// answer attributable.
///
/// What is actually under test: the second preview layer needs its own
/// `AVCaptureConnection` from the video input port (Task 076). That connection is a real
/// consumer of the capture pipeline, unlike the layer itself — which is why the
/// reported rise in `FrameWasLate` and `OutOfBuffers` after it started working is a
/// plausible consequence rather than a coincidence.
nonisolated struct SecondPreviewSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool

    /// Defaults to on — the layout shipped with it, and turning it off by default would
    /// silently change what the user sees before the measurement says it should.
    static let `default` = SecondPreviewSettings(isEnabled: true)
}

nonisolated struct SecondPreviewSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.secondPreviewSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SecondPreviewSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(SecondPreviewSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: SecondPreviewSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
