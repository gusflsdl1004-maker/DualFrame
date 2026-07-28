//
//  RecordingCheckpoint.swift
//  DualFrame
//

import Foundation

/// A snapshot of enough state to let a future recovery feature find and reason about
/// an interrupted recording. `RecordingCheckpointStore` persists this periodically
/// during recording — this task only writes/reads it; nothing resumes a recording
/// from it yet (see CLAUDE.md rules 21-24).
nonisolated struct RecordingCheckpoint: Codable, Equatable {
    let recordingState: RecordingState
    let outputURL: URL
    let recordingStartTime: Date
    let lastSampleTimestampSeconds: TimeInterval
    let recordingDuration: TimeInterval
    let selectedQuality: RecordingQuality
    let selectedFPS: RecordingFPS
}
