//
//  RecordingDiagnosticsService.swift
//  DualFrame
//

import Foundation

/// Persists one JSON file per recording session to
/// `Application Support/DualFrame/Diagnostics/`, and reads them back for the
/// Diagnostics screen. This never uploads, analyzes, or syncs anything — purely
/// local read/write.
actor RecordingDiagnosticsService {
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

    /// Requirement 5: each recording session creates exactly one diagnostics file,
    /// named after its `id` so a session is never accidentally overwritten by another.
    @discardableResult
    func save(_ diagnostics: RecordingDiagnostics) -> Bool {
        guard let url = try? fileURL(for: diagnostics.id) else { return false }
        guard let data = try? Self.encoder.encode(diagnostics) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Loads every saved session. Order is unspecified — the view model sorts.
    func loadAll() -> [RecordingDiagnostics] {
        guard let directory = try? diagnosticsDirectory(),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decoder.decode(RecordingDiagnostics.self, from: data)
        }
    }

    private func diagnosticsDirectory() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("DualFrame", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func fileURL(for id: String) throws -> URL {
        try diagnosticsDirectory().appendingPathComponent("\(id).json")
    }
}
