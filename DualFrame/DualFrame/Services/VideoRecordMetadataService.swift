//
//  VideoRecordMetadataService.swift
//  DualFrame
//

import Foundation

/// Persists one JSON file per `VideoRecord` (keyed by its `id`, i.e. its filename) to
/// `Application Support/DualFrame/VideoRecordMetadata/`, holding just its `sessionID`/
/// `outputProfile` tag (Task 024). Mirrors `RecordingDiagnosticsService`'s pattern.
///
/// Never touches the video file itself or `VideoRecord`'s own construction — this is a
/// pure sidecar, consistent with the Task 023/024 principle that new metadata only
/// ever references or tags existing data, never replaces or restructures it.
actor VideoRecordMetadataService {
    private let fileManager = FileManager.default

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        return encoder
    }()

    private static let decoder = JSONDecoder()

    @discardableResult
    func save(_ metadata: VideoRecordMetadata) -> Bool {
        guard let url = try? fileURL(for: metadata.videoRecordID) else { return false }
        guard let data = try? Self.encoder.encode(metadata) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func load(videoRecordID: String) -> VideoRecordMetadata? {
        guard let url = try? fileURL(for: videoRecordID),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? Self.decoder.decode(VideoRecordMetadata.self, from: data)
    }

    /// Called when the `VideoRecord` itself is deleted, so metadata never outlives the
    /// video it describes.
    func delete(videoRecordID: String) {
        guard let url = try? fileURL(for: videoRecordID) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func metadataDirectory() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("DualFrame", isDirectory: true)
            .appendingPathComponent("VideoRecordMetadata", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func fileURL(for videoRecordID: String) throws -> URL {
        try metadataDirectory().appendingPathComponent("\(videoRecordID).json")
    }
}
