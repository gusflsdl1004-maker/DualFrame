//
//  FileIntegrityValidator.swift
//  DualFrame
//

import Foundation

/// Checks whether a persisted `RecordingCheckpoint` still points at a real file and
/// contains internally consistent values. Used at launch to decide what to report in
/// the Recovery Status section — this never repairs or recovers anything itself.
nonisolated struct FileIntegrityValidator {
    /// True if the checkpoint's temporary recording file is still present on disk.
    /// A missing file means the recording can never be recovered, even once recovery
    /// itself is implemented (requirement 13).
    func temporaryFileExists(for checkpoint: RecordingCheckpoint) -> Bool {
        FileManager.default.fileExists(atPath: checkpoint.outputURL.path)
    }

    /// Structural sanity checks on a checkpoint that decoded successfully but might
    /// still hold nonsensical values (requirement 14, rule 28: detect corruption
    /// gracefully rather than trusting decoded data blindly).
    func isCheckpointValid(_ checkpoint: RecordingCheckpoint) -> Bool {
        guard checkpoint.outputURL.isFileURL,
              checkpoint.recordingDuration >= 0,
              checkpoint.lastSampleTimestampSeconds >= 0,
              checkpoint.recordingStartTime <= Date() else {
            return false
        }
        return true
    }
}
