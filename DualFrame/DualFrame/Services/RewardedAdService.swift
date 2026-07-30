//
//  RewardedAdService.swift
//  DualFrame
//

import Foundation

nonisolated enum RewardedAdOutcome: Equatable, Sendable {
    /// The user watched to the end and earned the reward. Only this permits an export.
    case rewarded
    /// The user closed the ad early. Requirement 4: no reward, so no save.
    case dismissedEarly
    /// No fill, network failure, SDK error. Requirement 4: **no save.**
    case failed(reason: String)
}

/// The whole surface an ad SDK has to satisfy. Requirement 6: keeping it this small is
/// what makes a real SDK a drop-in later — `ExportManager` is the only caller, and it
/// only ever needs "show one rewarded ad, tell me what happened".
///
/// Requirement 7 lives here too: nothing below `ExportManager` sees this protocol.
/// `RecordingService` and `ShortGenerationCoordinator` have no reference to it, no
/// import, and no knowledge that ads exist — recording and generation must keep working
/// identically whether or not there is ever an ad SDK in the project.
nonisolated protocol RewardedAdPresenting: Sendable {
    /// Returns only once the ad has finished, been dismissed, or failed.
    func presentRewardedAd() async -> RewardedAdOutcome
}

/// Stands in until a real SDK is integrated.
///
/// Deliberately **not** hardcoded to succeed. A mock that always rewards would mean the
/// failure path — the one that must refuse to save — never runs during development, and
/// that is exactly the path where a bug costs the user their export. The outcome comes
/// from `UserPlanSettings.mockAdOutcome`, which the diagnostics screen can flip, so
/// "reward", "dismissed early" and "failed to load" are all reachable at runtime.
nonisolated final class MockRewardedAdService: RewardedAdPresenting, @unchecked Sendable {
    /// How long the fake ad "plays" for. Non-zero by default so the UI's disabled state
    /// during playback is actually exercised rather than skipped over.
    private let duration: Duration
    private let settingsService: UserPlanSettingsService

    init(duration: Duration = .seconds(2), settingsService: UserPlanSettingsService = UserPlanSettingsService()) {
        self.duration = duration
        self.settingsService = settingsService
    }

    /// Read per presentation rather than captured at init, so flipping the outcome in
    /// the diagnostics screen takes effect on the very next export without rebuilding
    /// the object graph.
    func presentRewardedAd() async -> RewardedAdOutcome {
        try? await Task.sleep(for: duration)
        if Task.isCancelled { return .dismissedEarly }

        switch settingsService.load().mockAdOutcome ?? .reward {
        case .reward: return .rewarded
        case .dismissEarly: return .dismissedEarly
        case .fail: return .failed(reason: "광고를 불러오지 못했습니다. 저장되지 않았습니다.")
        }
    }
}
