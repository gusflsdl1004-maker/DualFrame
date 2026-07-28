//
//  RecordingDiagnostics.swift
//  DualFrame
//

import Foundation

/// A high-level summary of how a completed recording session went, for the
/// diagnostics detail screen. Distinct from `RecoveryStatus` (Task 016), which is
/// about whether a *leftover* checkpoint from a crashed session exists — this is a
/// backward-looking summary of one session that already finished.
nonisolated enum DiagnosticsRecoveryStatus: String, Codable, Equatable {
    case completedNormally
    case completedAfterInterruption
    case failed

    var title: String {
        switch self {
        case .completedNormally: "Completed Normally"
        case .completedAfterInterruption: "Completed After Interruption"
        case .failed: "Failed"
        }
    }
}

/// One recording session's diagnostics, persisted as a single JSON file. Read-only
/// once written — nothing in the app edits an existing diagnostics record.
nonisolated struct RecordingDiagnostics: Codable, Equatable, Identifiable {
    let id: String
    let recordingStartTime: Date
    let recordingEndTime: Date
    let recordingDuration: TimeInterval
    let resolution: RecordingQuality
    let fps: RecordingFPS
    let averageWriteLatency: TimeInterval
    let droppedVideoFrames: Int
    let droppedAudioBuffers: Int
    let peakMemoryUsageBytes: UInt64
    let availableStorageBytes: Int64
    let checkpointCount: Int
    let recoveryStatus: DiagnosticsRecoveryStatus
}
