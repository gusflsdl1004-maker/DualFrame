//
//  ExternalStorageExportService.swift
//  DualFrame
//

import Foundation

nonisolated enum ExternalStorageExportError: Error {
    case accessDenied
    case copyFailed
    case verificationFailed
}

/// The outcome of exporting a single recording to external storage, keyed per-recording.
nonisolated enum ExternalStorageExportStatus: Equatable {
    case idle
    case exporting
    case success
    case failed
}

/// Copies a recording from the internal library to a user-selected external storage
/// location. The internal library file is only ever read from — never moved or deleted.
/// An actor so the blocking `FileManager` copy runs off the main thread.
actor ExternalStorageExportService {
    /// Copies `record`'s video into `destinationDirectory` and verifies the copy.
    /// `destinationDirectory` must be a URL the user picked through the Files picker
    /// (see `ExternalStorageViewModel.selectedURL`).
    func export(record: VideoRecord, to destinationDirectory: URL) throws {
        guard destinationDirectory.startAccessingSecurityScopedResource() else {
            throw ExternalStorageExportError.accessDenied
        }
        defer { destinationDirectory.stopAccessingSecurityScopedResource() }

        let destinationFileURL = destinationDirectory.appendingPathComponent(record.filename)

        do {
            if FileManager.default.fileExists(atPath: destinationFileURL.path) {
                try FileManager.default.removeItem(at: destinationFileURL)
            }
            try FileManager.default.copyItem(at: record.localURL, to: destinationFileURL)
        } catch {
            throw ExternalStorageExportError.copyFailed
        }

        try verify(expectedFileSize: record.fileSize, at: destinationFileURL)
    }

    /// Confirms the copied file exists and its size matches the source exactly.
    private func verify(expectedFileSize: Int64, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExternalStorageExportError.verificationFailed
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let copiedFileSize = attributes[.size] as? Int64,
              copiedFileSize == expectedFileSize else {
            throw ExternalStorageExportError.verificationFailed
        }
    }
}
