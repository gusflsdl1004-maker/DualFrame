//
//  RecordingSessionMetadata.swift
//  DualFrame
//

import Foundation

/// Identifies one recording session from start to stop, so every output it produces
/// (long-form and/or short-form) can be linked back together by an exact identifier
/// instead of guessed from timing or file shape (Task 024).
///
/// Created exactly once per recording, by `RecordingViewModel.startRecording()`
/// (requirement 2) — `RecordingService` never sees or computes this itself, since this
/// task must not modify it (requirement 8). Handed to
/// `InternalVideoLibraryService.beginSession(_:)` so every `VideoRecord` imported until
/// `endSession()` is tagged with this `sessionID`, without `RecordingService`'s existing
/// `importRecording(...)` call site needing to change at all.
nonisolated struct RecordingSessionMetadata: Equatable {
    let sessionID: UUID
    let startedAt: Date
    let recordingMode: RecordingMode
    let selectedQuality: RecordingQuality
    let selectedFPS: RecordingFPS
    /// Task 042: the user-facing output mode this session was started with — captured
    /// once here (same reasoning as `recordingMode`/`selectedQuality`/`selectedFPS`
    /// already being captured at start time) so a settings change mid-recording can
    /// never retroactively relabel a `RecordingGroup` after the fact.
    let outputMode: RecordingOutputMode
}
