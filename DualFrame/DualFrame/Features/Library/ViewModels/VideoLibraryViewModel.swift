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

    private let libraryService: InternalVideoLibraryService
    private let groupService: RecordingGroupService
    private let externalStorageViewModel: ExternalStorageViewModel
    private let exportCoordinator: ExportCoordinator

    private var destinationContinuation: CheckedContinuation<StorageDestination?, Never>?
    private var deleteConfirmationContinuation: CheckedContinuation<Bool, Never>?

    init(
        libraryService: InternalVideoLibraryService,
        externalStorageViewModel: ExternalStorageViewModel,
        groupService: RecordingGroupService = RecordingGroupService(),
        exportCoordinator: ExportCoordinator? = nil
    ) {
        self.libraryService = libraryService
        self.externalStorageViewModel = externalStorageViewModel
        self.groupService = groupService
        self.exportCoordinator = exportCoordinator ?? ExportCoordinator(libraryService: libraryService)
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
