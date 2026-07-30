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
nonisolated enum ShortGenerationState: Equatable {
    /// Nothing to do — either no short-form was requested, or none has started yet.
    case idle
    /// Running. `progress` is 0...1, derived from presentation time over the source
    /// duration, so it is monotonic and does not depend on knowing the frame count.
    case generating(progress: Double)
    case finished
    case cancelled
    case failed(reason: String)

    var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }

    var progress: Double {
        if case let .generating(progress) = self { return progress }
        return self == .finished ? 1 : 0
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

    var averageCropMilliseconds: Double {
        frameCount > 0 ? cropSeconds / Double(frameCount) * 1_000 : 0
    }

    var averageEncodeMilliseconds: Double {
        frameCount > 0 ? encodeSeconds / Double(frameCount) * 1_000 : 0
    }

    /// How much faster than real time the pass ran. Above 1.0 means a 60-second
    /// recording generated in under 60 seconds.
    func speedRatio(sourceDuration: TimeInterval) -> Double {
        totalSeconds > 0 ? sourceDuration / totalSeconds : 0
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
