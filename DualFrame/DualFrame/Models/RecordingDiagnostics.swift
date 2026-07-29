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
    /// Task 063 item 4: which `alwaysDiscardsLateVideoFrames` setting was in force for
    /// this recording. Without it the two halves of the comparison run are
    /// indistinguishable after the fact, which is exactly how every measurement before
    /// Task 063 ended up unattributable. Optional so older records still decode.
    let lateFrameHandling: LateFrameHandling?
    /// Task 064: the encoder configuration this recording ran under, and — the part that
    /// settles it — the codec/profile/**level** parsed back out of the file that was
    /// actually written. The level is chosen by VideoToolbox, not by the app, and for
    /// H.264 it is what caps frame rate at a given resolution. All optional so records
    /// written before Task 064 still decode.
    let videoCodecPreference: VideoCodecPreference?
    let keyFrameIntervalSeconds: Int?
    let bitratePreset: BitratePreset?
    /// e.g. `hvc1 profile=1 tier=Main level=5.1` or `avc1 profile=100 level=5.1`.
    /// The long-form (or single-mode) writer's, never the short-form's.
    let savedVideoFormat: String?
    /// Task 065: what the codec selection decided, per writer, at the moment each writer
    /// was built — e.g. `Long-form: auto 3840x2160@60 → hvc1`.
    ///
    /// Paired with `savedVideoFormat`, which is read back out of the finished file, this
    /// separates two questions that have been conflated: what this app asked for, and
    /// what the encoder produced. Optional so older records still decode.
    let encoderDecisions: [String]?
    /// Task 065: every writer's readback, keyed by profile name — so the short-form's
    /// codec and rate are visible rather than silently replacing the long-form's.
    let savedVideoFormatsByProfile: [String: String]?
    let savedFrameRatesByProfile: [String: Float]?
    /// Task 066 item 1: `nominal` / `fair` / `serious` / `critical`.
    ///
    /// Three readings rather than one. The starting state alone cannot show throttling:
    /// a recording that begins `nominal` and ends `serious` was throttled partway
    /// through, and that is exactly the shape a thermal explanation for the frame rate
    /// would take. Optional so older records still decode.
    let thermalStateAtStart: String?
    let peakThermalState: String?
    let thermalStateAtEnd: String?
    /// Task 067: the first few dropped frames in full — reason, PTS, `systemUptime`,
    /// thermal state, our in-flight backlog, and every attachment on the buffer.
    let dropSamples: [String]?
    /// Every attachment key seen on any dropped buffer during the recording. CoreMedia
    /// declares only two; this reports what AVFoundation actually attached.
    let dropAttachmentKeys: [String]?

    /// Arrival rate implied by the frames that actually reached the writer.
    var measuredArrivalFPS: Double {
        recordingDuration > 0 ? Double(deliveredVideoFrames) / recordingDuration : 0
    }
}
