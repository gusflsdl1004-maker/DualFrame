//
//  VideoRecordMetadata.swift
//  DualFrame
//

import Foundation

/// The `sessionID`/`outputProfile` tag for one `VideoRecord` (Task 024). `VideoRecord`
/// itself is never persisted as JSON — it's rebuilt fresh from the file on disk every
/// time `InternalVideoLibraryService.loadAllRecords()` runs — so this small sidecar
/// record is what actually survives an app relaunch. Saved once, at import time, by
/// `InternalVideoLibraryService.importRecording(...)`; read back by `makeRecord(from:)`
/// to repopulate `VideoRecord.sessionID`/`.outputProfile` on every rescan.
///
/// A recording made before Task 024 has no file here at all — `VideoRecord.sessionID`/
/// `.outputProfile` simply come back `nil` for it, which is exactly what tells
/// `InternalVideoLibraryService.loadRecordingGroups(groupService:)` to fall back to the
/// Task 023 heuristic only for that recording (requirement 7).
nonisolated struct VideoRecordMetadata: Codable, Equatable {
    let videoRecordID: String
    let sessionID: UUID
    let outputProfile: OutputProfile
}
