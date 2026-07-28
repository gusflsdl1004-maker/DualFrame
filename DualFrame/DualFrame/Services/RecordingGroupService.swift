//
//  RecordingGroupService.swift
//  DualFrame
//

import Foundation

/// Persists one JSON file per `RecordingGroup` to
/// `Application Support/DualFrame/RecordingGroups/`, and reads them back for the
/// Library screen. Mirrors `RecordingDiagnosticsService`'s pattern exactly.
///
/// This never touches `VideoRecord`s or the files they point to — it only stores the
/// small reference records described in `Models/RecordingGroup.swift`. Deleting a
/// `RecordingGroup` here never deletes the underlying video; that stays
/// `InternalVideoLibraryService`'s job (Task 023 principle: groups only reference).
actor RecordingGroupService {
    private let fileManager = FileManager.default

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    @discardableResult
    func save(_ group: RecordingGroup) -> Bool {
        guard let url = try? fileURL(for: group.id) else { return false }
        guard let data = try? Self.encoder.encode(group) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Loads every saved group. Order is unspecified — the view model sorts.
    func loadAll() -> [RecordingGroup] {
        guard let directory = try? groupsDirectory(),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decoder.decode(RecordingGroup.self, from: data)
        }
    }

    /// Requirement 7: group-level deletion removes the group's own metadata. Does not
    /// touch any `VideoRecord` — the caller deletes those separately via
    /// `InternalVideoLibraryService`.
    func delete(id: String) {
        guard let url = try? fileURL(for: id) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func groupsDirectory() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("DualFrame", isDirectory: true)
            .appendingPathComponent("RecordingGroups", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func fileURL(for id: String) throws -> URL {
        try groupsDirectory().appendingPathComponent("\(id).json")
    }
}
