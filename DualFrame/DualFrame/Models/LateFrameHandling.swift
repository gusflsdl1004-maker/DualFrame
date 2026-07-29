//
//  LateFrameHandling.swift
//  DualFrame
//

import Foundation

/// What `AVCaptureVideoDataOutput` should do with a frame it cannot hand to the
/// delegate immediately — i.e. `alwaysDiscardsLateVideoFrames`.
///
/// Task 063: this exists as a *setting* rather than a constant because it is the one
/// remaining capture-stage variable whose effect cannot be reasoned about from the
/// code. Task 055 changed it from AVFoundation's default (`discard`) to `queue` on the
/// theory that discarding was what produced the climbing `lateDropped` count. The
/// measurements taken afterwards did not support that: late drops stayed in the same
/// range (267, then 291) while the saved file stayed at ~36fps. Both readings are from
/// `queue`, so nothing in the record actually compares the two.
///
/// Making it switchable at runtime turns "ship two builds and guess which one the
/// numbers came from" into one build, one switch, and two rows in the comparison
/// screen. The mode used is recorded into each session's `RecordingDiagnostics`, so a
/// result can never be attributed to the wrong setting.
///
/// Neither mode can lose an already-recorded frame: both describe what the *capture
/// output* does before a frame ever reaches the writer, and the writer's own path is
/// untouched (CLAUDE.md rule 1).
nonisolated enum LateFrameHandling: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `alwaysDiscardsLateVideoFrames = true` — AVFoundation's own default. A frame
    /// that becomes ready while the delegate is still busy is thrown away, and its
    /// pool buffer is recycled straight back. Frames are lost, but the pool never
    /// backs up.
    case discard
    /// `alwaysDiscardsLateVideoFrames = false` — the Task 055 setting. AVFoundation
    /// holds the late frame instead of discarding it, which keeps the frame but keeps
    /// its pool buffer checked out too. If the consumer is genuinely slower than the
    /// camera, this converts `FrameWasLate` into `OutOfBuffers` rather than removing
    /// the loss.
    case queue

    var id: String { rawValue }

    /// The value to assign to `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames`.
    var alwaysDiscardsLateVideoFrames: Bool {
        switch self {
        case .discard: true
        case .queue: false
        }
    }

    var title: String {
        switch self {
        case .discard: "늦은 프레임 버림 (기본)"
        case .queue: "늦은 프레임 대기"
        }
    }

    /// Short form, for the diagnostics comparison row where space is tight.
    var shortTitle: String {
        switch self {
        case .discard: "discard"
        case .queue: "queue"
        }
    }

    var detail: String {
        switch self {
        case .discard: "AVFoundation 기본값. 늦은 프레임을 버리고 버퍼를 즉시 반납합니다."
        case .queue: "Task 055 설정. 늦은 프레임을 유지하지만 캡처 풀 버퍼를 계속 점유합니다."
        }
    }
}

/// Persisted wrapper, matching the shape every other settings model in this project
/// uses (`RecordingFPSSettings`, `RecordingQualitySettings`, …).
nonisolated struct LateFrameHandlingSettings: Codable, Equatable, Sendable {
    var mode: LateFrameHandling

    /// Task 063: back to AVFoundation's own default. The Task 055 move to `queue` was
    /// made on an untested hypothesis and the numbers since have not backed it up, so
    /// the default returns to the value Apple ships and the alternative becomes the
    /// thing you opt into for a comparison run.
    static let `default` = LateFrameHandlingSettings(mode: .discard)
}
