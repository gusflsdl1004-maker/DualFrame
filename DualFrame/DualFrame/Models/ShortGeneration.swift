//
//  ShortGeneration.swift
//  DualFrame
//

import Foundation

/// Where post-processing short-form generation is, for the UI.
///
/// Task 069: the architecture moved from "write Long and Short at the same time" to
/// "write Long, then derive Short from it". Measurement forced this — Long alone
/// reaches 59.47fps at 4K60, Long + Short only 51.64fps, and replacing the crop
/// implementation entirely (CoreImage → VideoToolbox) moved it by 0.15fps. The cost was
/// never the crop; it was running a second writer during capture.
/// Task 072 P0-9: what the job is doing right now, so the banner can say something
/// more useful than a percentage. The user should be able to tell whether the app is
/// reading, converting, or filing the result.
nonisolated enum ShortGenerationStage: String, Codable, Equatable, Sendable {
    case analyzing
    case converting
    case encoding
    case saving

    var title: String {
        switch self {
        case .analyzing: "영상 분석"
        case .converting: "쇼츠 생성"
        case .encoding: "인코딩"
        case .saving: "저장 중"
        }
    }
}

nonisolated enum ShortGenerationState: Equatable {
    /// Nothing to do — either no short-form was requested, or none has started yet.
    case idle
    /// Running. `progress` is 0...1, derived from presentation time over the source
    /// duration, so it is monotonic and does not depend on knowing the frame count.
    ///
    /// `remainingSeconds` is `nil` until enough of the pass has run to extrapolate
    /// honestly — an estimate from the first few frames is noise, and showing a
    /// countdown that jumps around is worse than showing none.
    case generating(progress: Double, stage: ShortGenerationStage = .converting, remainingSeconds: Double? = nil)
    case finished
    case cancelled
    case failed(reason: String)

    var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }

    var progress: Double {
        if case let .generating(progress, _, _) = self { return progress }
        return self == .finished ? 1 : 0
    }

    var stageTitle: String? {
        switch self {
        case .generating(_, let stage, _): stage.title
        case .finished: "완료"
        default: nil
        }
    }

    /// Formatted as "남은 시간 약 18초", or `nil` while the estimate is still unreliable.
    var remainingText: String? {
        guard case let .generating(_, _, remaining) = self, let remaining, remaining >= 1 else { return nil }
        if remaining < 60 { return "남은 시간 약 \(Int(remaining.rounded()))초" }
        return "남은 시간 약 \(Int((remaining / 60).rounded()))분"
    }
}

/// What one generation run cost, for the diagnostics screen.
///
/// Kept separate from the real-time `WriterAppendStats`: these describe an offline pass
/// with `expectsMediaDataInRealTime = false`, where being slower than the frame interval
/// is normal and not a defect. Conflating them in one table would make both unreadable.
nonisolated struct ShortGenerationMetrics: Codable, Equatable {
    /// Which cropper ran — the same `CropBackend` the real-time path used to select.
    let backend: CropBackend
    let frameCount: Int
    /// Wall-clock time for the whole pass, including reader/writer setup and finish.
    let totalSeconds: TimeInterval
    /// Cumulative time inside the cropper.
    let cropSeconds: TimeInterval
    /// Cumulative time inside `append` — the encoder's share.
    let encodeSeconds: TimeInterval
    let succeeded: Bool
    /// The **source asset's** duration, read from the long-form file itself.
    ///
    /// Stored rather than taken from `RecordingDiagnostics.recordingDuration`, which is
    /// wall-clock between start and stop and includes setup — using it would skew
    /// `speedRatio`, and that is the number the ad length gets decided from. Optional so
    /// records written before this field still decode.
    let sourceDurationSeconds: TimeInterval?
    /// Task 073 P1-8: per-stage wall time, so the 5-minute generation can be attributed
    /// instead of guessed at.
    ///
    /// `readerSeconds` is time inside `copyNextSampleBuffer` — decoding 4K60 HEVC.
    /// `cropSeconds` and `encodeSeconds` (below) are the crop and the `append`.
    /// `finishSeconds` is `finishWriting`, which on a large file is not free.
    /// All optional so records written before this field still decode.
    let readerSeconds: TimeInterval?
    let finishSeconds: TimeInterval?
    /// `nominalFrameRate` read back from the generated short-form file. Distinct from
    /// `RecordingDiagnostics.savedNominalFrameRate`, which is the long-form file's — the
    /// two are now produced by different pipelines and need to be judged separately.
    let outputFrameRate: Float?

    /// Which stage dominated, as a share of the measured total. This is the answer the
    /// optimisation work needs — not the absolute numbers, but which one to attack.
    var stageShares: [(name: String, seconds: TimeInterval, share: Double)] {
        let stages: [(String, TimeInterval)] = [
            ("Reader (디코드)", readerSeconds ?? 0),
            ("Crop", cropSeconds),
            ("Encoder (append)", encodeSeconds),
            ("Writer (finish)", finishSeconds ?? 0)
        ]
        let measured = stages.reduce(0) { $0 + $1.1 }
        return stages.map { ($0.0, $0.1, measured > 0 ? $0.1 / measured : 0) }
    }

    /// Time inside the pass that none of the timed stages account for — thread hops,
    /// pool waits, and anything the pipeline spends blocked. A large value here means
    /// the stages are not the problem; the way they are sequenced is.
    var unaccountedSeconds: TimeInterval {
        max(0, totalSeconds - ((readerSeconds ?? 0) + cropSeconds + encodeSeconds + (finishSeconds ?? 0)))
    }

    var averageCropMilliseconds: Double {
        frameCount > 0 ? cropSeconds / Double(frameCount) * 1_000 : 0
    }

    var averageEncodeMilliseconds: Double {
        frameCount > 0 ? encodeSeconds / Double(frameCount) * 1_000 : 0
    }

    /// Frames processed per second of wall clock — how fast the generator *works*.
    ///
    /// Not the same thing as `outputFrameRate`, which is what the finished file plays
    /// at. A pass that emits a 60fps file at 500 frames/sec has `generationFPS` 500 and
    /// `outputFrameRate` 60.
    var generationFPS: Double {
        totalSeconds > 0 ? Double(frameCount) / totalSeconds : 0
    }

    /// How much faster than real time the pass ran — the figure that decides how long an
    /// ad has to be. `8.5` means a 3-minute recording generates in about 21 seconds.
    var speedRatio: Double {
        guard let sourceDurationSeconds, totalSeconds > 0 else { return 0 }
        return sourceDurationSeconds / totalSeconds
    }

    /// Estimated generation time for a recording of `duration`, at the speed this run
    /// achieved. What an "예상 시간" label and an ad length should be sized from.
    func estimatedSeconds(forSourceDuration duration: TimeInterval) -> Double? {
        guard speedRatio > 0 else { return nil }
        return duration / speedRatio
    }
}

nonisolated enum ShortGenerationError: LocalizedError, Equatable {
    case sourceUnreadable
    case noVideoTrack
    case writerSetupFailed
    case cropFailed
    case writeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceUnreadable: "원본 영상을 읽을 수 없습니다."
        case .noVideoTrack: "원본 영상에 비디오 트랙이 없습니다."
        case .writerSetupFailed: "쇼츠 writer를 준비하지 못했습니다."
        case .cropFailed: "크롭에 실패했습니다."
        case .writeFailed(let reason): "쇼츠 저장에 실패했습니다. (\(reason))"
        case .cancelled: "생성이 취소되었습니다."
        }
    }
}
