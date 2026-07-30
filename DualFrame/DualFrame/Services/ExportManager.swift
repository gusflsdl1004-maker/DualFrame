//
//  ExportManager.swift
//  DualFrame
//

import Foundation

/// The outcome of one user-initiated export, whatever it contained.
nonisolated enum PlanGatedExportResult: Equatable {
    /// Everything requested was exported.
    case success([StorageDestination])
    /// Some of a `.longAndShort` export landed and some did not — reported honestly
    /// rather than collapsed into "failed", because the files that *did* export are
    /// really there and the user should not be told otherwise.
    case partial(exported: [StorageDestination], failed: [ExportFailureReason])
    /// A free user did not earn the reward. Requirement 4: nothing is saved.
    case adNotRewarded(reason: String)
    case cancelled
    case failed(ExportFailureReason)
    /// The target asked for a file this recording does not have — e.g. short-form
    /// export before generation finished.
    case nothingToExport
}

/// Task 071: the single place in the app that knows the user's plan.
///
/// **Requirement 7 is a layering rule, and this type is where it is enforced.**
/// `RecordingService` and `ShortGenerationCoordinator` do not import
/// `RewardedAdPresenting`, do not hold a `UserPlan`, and behave identically whether the
/// user is free or Pro. Recording and short-form generation are not products to be
/// gated — the *export to the camera roll* is. That keeps CLAUDE.md rule 1 intact by
/// construction: no monetisation path can ever sit between a frame and the disk.
///
/// It wraps `ExportCoordinator` rather than replacing it. Destination resolution,
/// external-drive handling, and the delete-internal-copy confirmation are unchanged and
/// still live there; this only decides *whether* that runs.
@MainActor
final class ExportManager {
    private let exportCoordinator: ExportCoordinator
    private let adService: RewardedAdPresenting
    private let planSettingsService: UserPlanSettingsService

    init(
        exportCoordinator: ExportCoordinator,
        adService: RewardedAdPresenting = MockRewardedAdService(),
        planSettingsService: UserPlanSettingsService = UserPlanSettingsService()
    ) {
        self.exportCoordinator = exportCoordinator
        self.adService = adService
        self.planSettingsService = planSettingsService
    }

    var currentPlan: UserPlan { planSettingsService.load().plan }

    /// Exports whichever files `target` names from `group`.
    ///
    /// The ad is shown **once per user action**, not once per file: a free user
    /// exporting Long + Short watches one ad, because they asked for one thing.
    ///
    /// Ordering is deliberate — the reward is earned *before* anything is written. A
    /// free user who abandons the ad has changed nothing on disk, and the internal
    /// library copies are untouched in every failure path here.
    func export(
        target: ExportTarget,
        group: ResolvedRecordingGroup,
        externalDestinationURL: URL?,
        chooseDestination: @escaping ([StorageDestination]) async -> StorageDestination?,
        confirmDelete: @escaping () async -> Bool,
        onAdPresenting: @MainActor (Bool) -> Void = { _ in }
    ) async -> PlanGatedExportResult {
        let records = Self.records(for: target, in: group)
        guard !records.isEmpty else { return .nothingToExport }

        if currentPlan.requiresRewardedAdForExport {
            onAdPresenting(true)
            let outcome = await adService.presentRewardedAd()
            onAdPresenting(false)

            switch outcome {
            case .rewarded:
                break
            case .dismissedEarly:
                // Requirement 4: no reward means no save. Not treated as an error —
                // the user chose to stop, and saying "실패" for a deliberate choice is
                // misleading.
                return .adNotRewarded(reason: "광고를 끝까지 시청해야 저장됩니다.")
            case .failed(let reason):
                // Requirement 4 again, and the important half: an ad that *fails* also
                // does not save. It must never silently fall through to a free export.
                return .adNotRewarded(reason: reason)
            }
        }

        var exported: [StorageDestination] = []
        var failures: [ExportFailureReason] = []
        var cancelledAny = false

        for record in records {
            let result = await exportCoordinator.export(
                record,
                externalDestinationURL: externalDestinationURL,
                chooseDestination: chooseDestination,
                confirmDelete: confirmDelete
            )
            switch result {
            case .success(let destination, _):
                exported.append(destination)
            case .cancelled:
                cancelledAny = true
            case .failed(let reason):
                failures.append(reason)
            }
        }

        if exported.isEmpty {
            if let first = failures.first { return .failed(first) }
            return cancelledAny ? .cancelled : .nothingToExport
        }
        if failures.isEmpty && !cancelledAny {
            return .success(exported)
        }
        return .partial(exported: exported, failed: failures)
    }

    /// Which records a target maps to, skipping anything the group does not actually
    /// have. A short-form export requested while generation is still running resolves to
    /// nothing and returns `.nothingToExport` rather than exporting the long-form file
    /// by mistake.
    private static func records(for target: ExportTarget, in group: ResolvedRecordingGroup) -> [VideoRecord] {
        switch target {
        case .longOnly:
            [group.long.record].compactMap { $0 }
        case .shortOnly:
            [group.displayedShort.record].compactMap { $0 }
        case .longAndShort:
            [group.long.record, group.displayedShort.record].compactMap { $0 }
        }
    }
}
