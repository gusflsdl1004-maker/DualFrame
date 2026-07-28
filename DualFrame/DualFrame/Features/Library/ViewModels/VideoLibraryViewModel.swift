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

    private let libraryService: InternalVideoLibraryService

    init(libraryService: InternalVideoLibraryService) {
        self.libraryService = libraryService
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
