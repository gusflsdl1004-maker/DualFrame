//
//  VideoLibraryViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and manages the internal video library for display.
/// Owns no file I/O itself — that lives in `InternalVideoLibraryService`.
@MainActor
final class VideoLibraryViewModel: ObservableObject {
    @Published private(set) var records: [VideoRecord] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var exportStatuses: [String: PhotoLibraryExportStatus] = [:]

    private let libraryService: InternalVideoLibraryService
    private let exportService: PhotoLibraryExportService

    init(
        libraryService: InternalVideoLibraryService,
        exportService: PhotoLibraryExportService = PhotoLibraryExportService()
    ) {
        self.libraryService = libraryService
        self.exportService = exportService
    }

    func exportStatus(for record: VideoRecord) -> PhotoLibraryExportStatus {
        exportStatuses[record.id] ?? .idle
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
