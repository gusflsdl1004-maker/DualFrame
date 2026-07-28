//
//  ExportCoordinator.swift
//  DualFrame
//

import Foundation

/// Why an export attempt failed, so the UI can react appropriately
/// (e.g. offer a Settings shortcut for a permission problem).
nonisolated enum ExportFailureReason: Equatable {
    case photosPermissionDenied
    case copyFailed
}

/// The outcome of running `ExportCoordinator.export`.
nonisolated enum ExportResult: Equatable {
    case success(destination: StorageDestination, internalCopyDeleted: Bool)
    case cancelled
    case failed(ExportFailureReason)
}

/// Per-recording export state for display.
nonisolated enum ExportState: Equatable {
    case idle
    case exporting
    case success(StorageDestination)
    case failed(ExportFailureReason)
}

/// Centralizes every export decision — which destination to use, whether to ask the
/// user first, and whether to offer deleting the internal copy afterward — all driven
/// by `StorageSettings`. This is the *only* place that decides those things; it calls
/// the existing `InternalVideoLibraryService`, `PhotoLibraryExportService`, and
/// `ExternalStorageExportService` to do the actual work rather than duplicating it.
///
/// The two closures let the caller (a view model) present the actual UI — this type
/// only decides *when* to ask, never *how* to ask.
nonisolated struct ExportCoordinator {
    private let settingsService: StorageSettingsService
    private let libraryService: InternalVideoLibraryService
    private let photosExportService: PhotoLibraryExportService
    private let externalExportService: ExternalStorageExportService

    init(
        libraryService: InternalVideoLibraryService,
        settingsService: StorageSettingsService = StorageSettingsService(),
        photosExportService: PhotoLibraryExportService = PhotoLibraryExportService(),
        externalExportService: ExternalStorageExportService = ExternalStorageExportService()
    ) {
        self.libraryService = libraryService
        self.settingsService = settingsService
        self.photosExportService = photosExportService
        self.externalExportService = externalExportService
    }

    /// Runs the full export flow for `record`.
    ///
    /// Reads `StorageSettings` fresh (requirement: read before every export). If
    /// `askEveryTime` is on, asks `chooseDestination` with the currently available
    /// choices (external storage only included when `externalDestinationURL` is set);
    /// otherwise uses `defaultDestination` automatically. After a successful export,
    /// if `keepInternalCopy` is off, asks `confirmDelete` before removing the internal
    /// copy — it is never deleted without that confirmation.
    func export(
        _ record: VideoRecord,
        externalDestinationURL: URL?,
        chooseDestination: ([StorageDestination]) async -> StorageDestination?,
        confirmDelete: () async -> Bool
    ) async -> ExportResult {
        let settings = settingsService.load()

        guard let destination = await resolveDestination(
            settings: settings,
            externalDestinationURL: externalDestinationURL,
            chooseDestination: chooseDestination
        ) else {
            return .cancelled
        }

        if let failureReason = await performExport(record, to: destination, externalDestinationURL: externalDestinationURL) {
            return .failed(failureReason)
        }

        let internalCopyDeleted = await deleteInternalCopyIfNeeded(
            record,
            destination: destination,
            settings: settings,
            confirmDelete: confirmDelete
        )

        return .success(destination: destination, internalCopyDeleted: internalCopyDeleted)
    }

    private func resolveDestination(
        settings: StorageSettings,
        externalDestinationURL: URL?,
        chooseDestination: ([StorageDestination]) async -> StorageDestination?
    ) async -> StorageDestination? {
        guard settings.askEveryTime else {
            return settings.defaultDestination
        }

        var choices: [StorageDestination] = [.internalLibrary, .photos]
        if externalDestinationURL != nil {
            choices.append(.externalDrive)
        }
        return await chooseDestination(choices)
    }

    private func performExport(
        _ record: VideoRecord,
        to destination: StorageDestination,
        externalDestinationURL: URL?
    ) async -> ExportFailureReason? {
        switch destination {
        case .internalLibrary:
            // Already there — nothing to copy.
            return nil

        case .photos:
            do {
                try await photosExportService.exportVideo(at: record.localURL)
                return nil
            } catch PhotoLibraryExportError.permissionDenied {
                return .photosPermissionDenied
            } catch {
                return .copyFailed
            }

        case .externalDrive:
            guard let url = externalDestinationURL else { return .copyFailed }
            do {
                try await externalExportService.export(record: record, to: url)
                return nil
            } catch {
                return .copyFailed
            }
        }
    }

    private func deleteInternalCopyIfNeeded(
        _ record: VideoRecord,
        destination: StorageDestination,
        settings: StorageSettings,
        confirmDelete: () async -> Bool
    ) async -> Bool {
        guard !settings.keepInternalCopy, destination != .internalLibrary else {
            return false
        }
        guard await confirmDelete() else {
            return false
        }
        return (try? await libraryService.delete(record)) != nil
    }
}
