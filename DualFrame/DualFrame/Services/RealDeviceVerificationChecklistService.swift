//
//  RealDeviceVerificationChecklistService.swift
//  DualFrame
//

#if DEBUG
import Foundation

/// Persists which `RealDeviceVerificationItem`s a tester has confirmed on a physical
/// device (Task 031). Mirrors `RecordingQualitySettingsService`'s `UserDefaults`
/// pattern. QA/dev tooling only — never read by the recording pipeline, so a
/// missing or corrupted entry here can never affect a recording.
nonisolated struct RealDeviceVerificationChecklistService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.realDeviceVerificationChecklist"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [RealDeviceVerificationItem: Bool] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        var result: [RealDeviceVerificationItem: Bool] = [:]
        for (rawValue, checked) in stored {
            if let item = RealDeviceVerificationItem(rawValue: rawValue) {
                result[item] = checked
            }
        }
        return result
    }

    func setChecked(_ checked: Bool, for item: RealDeviceVerificationItem) {
        var stored = load()
        stored[item] = checked
        let rawDict = Dictionary(uniqueKeysWithValues: stored.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(rawDict) else { return }
        defaults.set(data, forKey: key)
    }
}
#endif
