//
//  RecordingCheckpointStore.swift
//  DualFrame
//

import Foundation

/// Persists a `RecordingCheckpoint` to `Application Support/DualFrame/recording_checkpoint.json`,
/// so a crash or unexpected termination during recording leaves enough information
/// behind for a future recovery feature to find. This only writes/reads/deletes the
/// checkpoint file — it does not resume or recover a recording (see CLAUDE.md rules 21-24).
///
/// An actor so its file I/O runs off whatever caller invoked it, and so concurrent
/// save/delete calls are naturally serialized (rule 26: never overwrite without a
/// consistent view of the previous state).
actor RecordingCheckpointStore {
    private let fileManager = FileManager.default
    private let filename = "recording_checkpoint.json"

    /// Writes the checkpoint atomically (requirement 5, rule 25). Failures are logged
    /// and swallowed rather than thrown — a checkpoint write failing must never affect
    /// the recording itself (requirement 6, rule 28).
    func save(_ checkpoint: RecordingCheckpoint) async {
        guard let url = try? checkpointURL() else { return }
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Returns the last saved checkpoint, or `nil` if none exists or it failed to
    /// decode (treated as "no usable checkpoint" rather than a crash — rule 28).
    func load() -> RecordingCheckpoint? {
        guard let url = try? checkpointURL(),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(RecordingCheckpoint.self, from: data)
    }

    func exists() -> Bool {
        guard let url = try? checkpointURL() else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    /// Requirement 7: called only after a recording completes and validates successfully.
    func delete() {
        guard let url = try? checkpointURL() else { return }
        try? fileManager.removeItem(at: url)
    }

    private func checkpointURL() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("DualFrame", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(filename)
    }
}
