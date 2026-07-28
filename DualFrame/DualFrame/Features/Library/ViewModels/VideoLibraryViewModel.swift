//
//  VideoLibraryViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and manages the internal video library for display, and runs the
/// settings-driven export flow through `ExportCoordinator`. This view model only
/// presents UI (destination picker, delete confirmation) when the coordinator asks
/// for it — it makes no export decisions itself.
@MainActor
final class VideoLibraryViewModel: ObservableObject {
    @Published private(set) var records: [VideoRecord] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var exportStates: [String: ExportState] = [:]

    /// Non-nil while `ExportCoordinator` is waiting for the user to pick a destination.
    @Published private(set) var pendingDestinationChoices: [StorageDestination]?
    /// True while `ExportCoordinator` is waiting for delete confirmation.
    @Published private(set) var isConfirmingDelete = false

    private let libraryService: InternalVideoLibraryService
    private let externalStorageViewModel: ExternalStorageViewModel
    private let exportCoordinator: ExportCoordinator

    private var destinationContinuation: CheckedContinuation<StorageDestination?, Never>?
    private var deleteConfirmationContinuation: CheckedContinuation<Bool, Never>?

    init(
        libraryService: InternalVideoLibraryService,
        externalStorageViewModel: ExternalStorageViewModel,
        exportCoordinator: ExportCoordinator? = nil
    ) {
        self.libraryService = libraryService
        self.externalStorageViewModel = externalStorageViewModel
        self.exportCoordinator = exportCoordinator ?? ExportCoordinator(libraryService: libraryService)
    }

    func exportState(for record: VideoRecord) -> ExportState {
        exportStates[record.id] ?? .idle
    }

    /// Runs the settings-driven export flow for `record`. Always user-initiated —
    /// never called automatically after a recording finishes.
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
                records.removeAll { $0.id == record.id }
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

    /// Rescans the library directory and sorts the results newest first.
    func refresh() async {
        do {
            let loaded = try await libraryService.loadAllRecords()
            records = loaded.sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
        } catch {
            errorMessage = "Could not load the video library."
        }
    }

    func delete(_ record: VideoRecord) async {
        do {
            try await libraryService.delete(record)
            records.removeAll { $0.id == record.id }
        } catch {
            errorMessage = "Could not delete the recording."
        }
    }
}
