//
//  VideoLibraryViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and manages the internal video library for display, grouped into
/// `ResolvedRecordingGroup`s (Task 023), and runs the settings-driven export flow
/// through `ExportCoordinator` for individual `VideoRecord`s. This view model only
/// presents UI (destination picker, delete confirmation) when the coordinator asks
/// for it — it makes no export decisions itself, and no grouping decisions either
/// (those live in `InternalVideoLibraryService.loadRecordingGroups(groupService:)`).
@MainActor
final class VideoLibraryViewModel: ObservableObject {
    @Published private(set) var groups: [ResolvedRecordingGroup] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var exportStates: [String: ExportState] = [:]

    /// Non-nil while `ExportCoordinator` is waiting for the user to pick a destination.
    @Published private(set) var pendingDestinationChoices: [StorageDestination]?
    /// True while `ExportCoordinator` is waiting for delete confirmation.
    @Published private(set) var isConfirmingDelete = false
    /// Task 071: true while a rewarded ad is on screen, so the UI can disable export
    /// controls instead of letting a second export start behind the ad.
    @Published private(set) var isPresentingAd = false
    /// The result of the last group-level export, for the banner. Cleared on dismiss.
    @Published var lastExportMessage: String?
    /// Task 071: shown in the UI so it is obvious which branch is in effect. Read
    /// through `ExportManager`, which is the only type that knows the plan.
    var currentPlan: UserPlan { exportManager.currentPlan }

    private let libraryService: InternalVideoLibraryService
    private let groupService: RecordingGroupService
    private let externalStorageViewModel: ExternalStorageViewModel
    private let exportCoordinator: ExportCoordinator
    /// Task 071: plan gating lives entirely behind this. This view model does not read
    /// `UserPlan` or know that ads exist beyond showing `isPresentingAd`.
    private let exportManager: ExportManager

    private var destinationContinuation: CheckedContinuation<StorageDestination?, Never>?
    private var deleteConfirmationContinuation: CheckedContinuation<Bool, Never>?

    init(
        libraryService: InternalVideoLibraryService,
        externalStorageViewModel: ExternalStorageViewModel,
        groupService: RecordingGroupService = RecordingGroupService(),
        exportCoordinator: ExportCoordinator? = nil,
        exportManager: ExportManager? = nil
    ) {
        self.libraryService = libraryService
        self.externalStorageViewModel = externalStorageViewModel
        self.groupService = groupService
        let coordinator = exportCoordinator ?? ExportCoordinator(libraryService: libraryService)
        self.exportCoordinator = coordinator
        self.exportManager = exportManager ?? ExportManager(exportCoordinator: coordinator)
    }

    /// Task 071 requirement 4/5: the plan-gated export. Free users watch a rewarded ad
    /// first and nothing is written unless they earn the reward; Pro exports straight
    /// away. Which of those happens is decided inside `ExportManager` — this method is
    /// identical for both.
    func export(target: ExportTarget, group: ResolvedRecordingGroup) async {
        let result = await exportManager.export(
            target: target,
            group: group,
            externalDestinationURL: externalStorageViewModel.selectedURL,
            chooseDestination: { [self] choices in await promptForDestination(choices) },
            confirmDelete: { [self] in await promptForDeleteConfirmation() },
            onAdPresenting: { [weak self] presenting in self?.isPresentingAd = presenting }
        )

        switch result {
        case .success(let destinations):
            lastExportMessage = "저장 완료 (\(destinations.count)개)"
            await refresh()
        case .partial(let exported, let failed):
            // Reported as-is rather than as a plain failure: the exported files really
            // are saved, and telling the user otherwise would be wrong. "실패 0" would
            // be nonsense, so a partial caused purely by cancelling the destination
            // picker is worded as cancellation rather than failure.
            lastExportMessage = failed.isEmpty
                ? "\(exported.count)개만 저장되었습니다. 나머지는 취소되었습니다."
                : "일부만 저장되었습니다 — 성공 \(exported.count), 실패 \(failed.count)"
            await refresh()
        case .adNotRewarded(let reason):
            lastExportMessage = reason
        case .cancelled:
            lastExportMessage = nil
        case .failed:
            lastExportMessage = "저장에 실패했습니다."
        case .nothingToExport:
            lastExportMessage = "저장할 영상이 아직 없습니다."
        }
    }

    func exportState(for record: VideoRecord) -> ExportState {
        exportStates[record.id] ?? .idle
    }

    /// Runs the settings-driven export flow for `record`. Always user-initiated —
    /// never called automatically after a recording finishes. Unchanged from before
    /// Task 023 — still the same `ExportCoordinator` call, just reused for whichever
    /// `VideoRecord` a `RecordingGroup` row's Export button was tapped for.
    func export(_ record: VideoRecord) async {
        exportStates[record.id] = .exporting

        let result = await exportCoordinator.export(
            record,
            externalDestinationURL: externalStorageViewModel.selectedURL,
            chooseDestination: { [self] choices in await promptForDestination(choices) },
            confirmDelete: { [self] in await promptForDeleteConfirmation() }
        )

        switch result {
        case .success(let destination, let internalCopyDeleted):
            exportStates[record.id] = .success(destination)
            if internalCopyDeleted {
                await refresh()
            }
        case .cancelled:
            exportStates[record.id] = .idle
        case .failed(let reason):
            exportStates[record.id] = .failed(reason)
        }
    }

    /// Called by the view once the user has tapped a destination (or cancelled, with `nil`).
    func resolveDestinationChoice(_ destination: StorageDestination?) {
        pendingDestinationChoices = nil
        destinationContinuation?.resume(returning: destination)
        destinationContinuation = nil
    }

    /// Called by the view once the user has answered the delete-confirmation prompt.
    func resolveDeleteConfirmation(_ confirmed: Bool) {
        isConfirmingDelete = false
        deleteConfirmationContinuation?.resume(returning: confirmed)
        deleteConfirmationContinuation = nil
    }

    private func promptForDestination(_ choices: [StorageDestination]) async -> StorageDestination? {
        await withCheckedContinuation { continuation in
            destinationContinuation = continuation
            pendingDestinationChoices = choices
        }
    }

    private func promptForDeleteConfirmation() async -> Bool {
        await withCheckedContinuation { continuation in
            deleteConfirmationContinuation = continuation
            isConfirmingDelete = true
        }
    }

    /// Rescans the library directory and its `RecordingGroup` metadata, newest first.
    func refresh() async {
        do {
            groups = try await libraryService.loadRecordingGroups(groupService: groupService)
            errorMessage = nil
        } catch {
            errorMessage = "Could not load the video library."
        }
    }

    /// Deletes one recording (requirement 7: individual deletion). Leaves the rest of
    /// its `RecordingGroup` — and any other group — untouched; a missing reference
    /// resolves to `.missing` next refresh rather than breaking the group.
    func delete(_ record: VideoRecord) async {
        do {
            try await libraryService.delete(record)
            await refresh()
        } catch {
            errorMessage = "Could not delete the recording."
        }
    }

    /// Task 090 P1-1: empties the app's own library.
    ///
    /// **Only the app's internal storage.** Anything already exported to Photos is a
    /// separate copy owned by Photos and is never touched — this deletes what the app
    /// itself is holding, which is the storage the user is trying to reclaim.
    ///
    /// Built entirely out of the existing per-group and per-record deletes rather than a
    /// new bulk primitive. The single-item path already removes the file, its metadata
    /// record and the group JSON in the right order, and it is the path that has been in
    /// use since Task 007; a faster bulk delete would be a second implementation of the
    /// most destructive operation in the app (CLAUDE.md rule 1).
    ///
    /// The second pass is not redundant. `loadRecordingGroups` surfaces unreferenced
    /// records as their own single-item groups, so the first pass should cover
    /// everything — but "should" is not good enough for a function whose whole purpose is
    /// that nothing is left occupying storage. Anything the group pass missed is deleted
    /// directly, and only then is the count reported.
    ///
    /// Best-effort per item: one failure never stops the rest, and a failure leaves that
    /// file intact rather than orphaning its metadata.
    @discardableResult
    func deleteAll() async -> Int {
        var deleted = 0
        for group in groups {
            for member in [group.long, group.short] {
                if case .succeeded(let record) = member {
                    if (try? await libraryService.delete(record)) != nil { deleted += 1 }
                }
            }
            await groupService.delete(id: group.id)
        }

        if let stragglers = try? await libraryService.loadAllRecords() {
            for record in stragglers {
                if (try? await libraryService.delete(record)) != nil { deleted += 1 }
            }
        }

        await refresh()
        return deleted
    }

    /// Deletes every recording in `group`, plus the group's own metadata (requirement 7:
    /// group-level deletion). Best-effort per member — one failing to delete doesn't
    /// stop the others.
    func delete(_ group: ResolvedRecordingGroup) async {
        for member in [group.long, group.short] {
            if case .succeeded(let record) = member {
                try? await libraryService.delete(record)
            }
        }
        await groupService.delete(id: group.id)
        await refresh()
    }
}
