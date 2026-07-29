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
        case .completedNormally: "정상 완료"
        case .completedAfterInterruption: "중단 후 완료"
        case .failed: "실패"
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
    /// Task 057 item 3: the four figures needed to judge real performance, recorded in
    /// **every** configuration rather than only Debug — Release is where the answer
    /// actually matters, and printing them there would reintroduce the very stall
    /// Task 057 removed. All are plain counters read once at the end of a recording.
    ///
    /// Frames that reached the writer. Divided by `recordingDuration` this is the
    /// arrival rate, i.e. the Release equivalent of `measuredArrivalFPS`.
    let deliveredVideoFrames: Int
    /// Frames the delivery stream discarded because the consumer was behind
    /// (`yieldDropped`). `droppedVideoFrames` above is AVFoundation's own late drop.
    let droppedBeforeConsumer: Int
    /// `nominalFrameRate` read back from the saved file — the number that finally
    /// decides whether 60fps was achieved.
    let savedNominalFrameRate: Float
    /// Task 059: per-writer accept/reject census. Optional so diagnostics saved before
    /// this task still decode unchanged (synthesised Decodable treats a missing key as
    /// nil) — no migration.
    let writerStats: [WriterAppendStats]?
    /// Task 060 item 1: AVFoundation's own reason for each frame it discarded before
    /// the delegate ran, keyed by reason name. Optional so older records still decode.
    let droppedFrameReasons: [String: Int]?

    /// Arrival rate implied by the frames that actually reached the writer.
    var measuredArrivalFPS: Double {
        recordingDuration > 0 ? Double(deliveredVideoFrames) / recordingDuration : 0
    }
}
