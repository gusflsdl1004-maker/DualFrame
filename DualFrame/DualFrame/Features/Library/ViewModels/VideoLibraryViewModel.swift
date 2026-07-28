//
//  VideoLibraryViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and manages the internal video library for display, and exports recordings
/// to Photos or external storage. Owns no file I/O itself — that lives in
/// `InternalVideoLibraryService`, `PhotoLibraryExportService`, and
/// `ExternalStorageExportService`.
@MainActor
final class VideoLibraryViewModel: ObservableObject {
    @Published private(set) var records: [VideoRecord] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var exportStatuses: [String: PhotoLibraryExportStatus] = [:]
    @Published private(set) var externalExportStatuses: [String: ExternalStorageExportStatus] = [:]
    @Published private(set) var externalExportErrorMessages: [String: String] = [:]

    private let libraryService: InternalVideoLibraryService
    private let exportService: PhotoLibraryExportService
    private let externalExportService: ExternalStorageExportService
    private let externalStorageViewModel: ExternalStorageViewModel

    init(
        libraryService: InternalVideoLibraryService,
        externalStorageViewModel: ExternalStorageViewModel,
        exportService: PhotoLibraryExportService = PhotoLibraryExportService(),
        externalExportService: ExternalStorageExportService = ExternalStorageExportService()
    ) {
        self.libraryService = libraryService
        self.externalStorageViewModel = externalStorageViewModel
        self.exportService = exportService
        self.externalExportService = externalExportService
    }

    func exportStatus(for record: VideoRecord) -> PhotoLibraryExportStatus {
        exportStatuses[record.id] ?? .idle
    }

    func externalExportStatus(for record: VideoRecord) -> ExternalStorageExportStatus {
        externalExportStatuses[record.id] ?? .idle
    }

    /// Copies `record`'s video into Photos. Always user-initiated — never called
    /// automatically after a recording finishes. The internal library file is untouched.
    func exportToPhotos(_ record: VideoRecord) async {
        exportStatuses[record.id] = .exporting
        do {
            try await exportService.exportVideo(at: record.localURL)
            exportStatuses[record.id] = .success
        } catch PhotoLibraryExportError.permissionDenied {
            exportStatuses[record.id] = .failed(permissionDenied: true)
        } catch {
            exportStatuses[record.id] = .failed(permissionDenied: false)
        }
    }

    /// Copies `record`'s video to the external storage location connected in
    /// Settings. Always user-initiated. The internal library file is only read from —
    /// never moved or deleted.
    func exportToExternalStorage(_ record: VideoRecord) async {
        guard let destinationURL = externalStorageViewModel.selectedURL else {
            externalExportStatuses[record.id] = .failed
            externalExportErrorMessages[record.id] = "Connect an external storage location in Settings first."
            return
        }

        externalExportStatuses[record.id] = .exporting
        externalExportErrorMessages[record.id] = nil

        do {
            try await externalExportService.export(record: record, to: destinationURL)
            externalExportStatuses[record.id] = .success
        } catch {
            externalExportStatuses[record.id] = .failed
            externalExportErrorMessages[record.id] = "Export failed. Please try again."
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
