//
//  VideoEncoderSettings.swift
//  DualFrame
//

import AVFoundation

/// Which codec the writer's `AVVideoCodecKey` should be.
///
/// Task 064: **this is the strongest remaining explanation for 4K60.**
///
/// H.264 levels cap frame rate by macroblock throughput, not by resolution. A 4K frame
/// is (3840/16)×(2160/16) = 32,400 macroblocks, and the level ceilings are:
///
///     Level 5.0   MaxMBPS   589,824  ->  4K @ 18fps
///     Level 5.1   MaxMBPS   983,040  ->  4K @ 30fps
///     Level 5.2   MaxMBPS 2,073,600  ->  4K @ 64fps
///
/// Apple's hardware H.264 encoder tops out at Level 5.1 on iPhone. That is why iOS's own
/// 카메라 → 포맷 → "높은 호환성"(H.264) offers 4K at 24/30 only, while "고효율"(HEVC)
/// offers 4K60: **4K60 in H.264 is outside what the hardware encoder supports.** HEVC
/// has no equivalent ceiling here — Main tier Level 5.1 covers 4K60 comfortably.
///
/// `RecordingService` has hardcoded `.h264` since it was written, so every 4K60
/// measurement in this project was taken against an encoder configuration that cannot
/// reach 60fps by specification. That is consistent with everything measured: the writer
/// accepts what it is offered, the capture stage is starving, and ~18ms per frame goes
/// somewhere outside this app's code.
nonisolated enum VideoCodecPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Pick per format: HEVC when H.264 could not sustain the requested rate, H.264
    /// otherwise. The default, and the only value that is a *fix* rather than a probe.
    case auto
    /// Force H.264. Kept selectable because it is the most widely compatible output and
    /// because the comparison in Task 064 needs the old behaviour reproducible.
    case h264
    /// Force HEVC.
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "자동 (권장)"
        case .h264: "H.264 고정"
        case .hevc: "HEVC 고정"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: "auto"
        case .h264: "h264"
        case .hevc: "hevc"
        }
    }

    var detail: String {
        switch self {
        case .auto: "H.264로 감당할 수 없는 해상도/FPS에서만 HEVC를 사용합니다. 4K60은 HEVC가 됩니다."
        case .h264: "호환성이 가장 높지만 4K60은 하드웨어 인코더 사양을 넘습니다."
        case .hevc: "항상 HEVC. 같은 비트레이트에서 화질이 높고 인코더 부하가 낮습니다."
        }
    }

    /// A 4K frame's macroblock count times the frame rate, against Level 5.1's
    /// `MaxMBPS`. Deliberately expressed as the real constraint rather than a hardcoded
    /// "4K60 → HEVC" special case, so 4K30, 1080p60 and the 1080×1920 short-form output
    /// each land on the correct answer without a separate rule.
    private static let h264Level51MaxMacroblocksPerSecond = 983_040

    static func exceedsH264HardwareCeiling(width: Int, height: Int, fps: Int) -> Bool {
        let macroblocksPerFrame = ((width + 15) / 16) * ((height + 15) / 16)
        return macroblocksPerFrame * fps > h264Level51MaxMacroblocksPerSecond
    }

    /// The codec to actually configure the writer with, for one output's format.
    func resolvedCodec(width: Int, height: Int, fps: Int) -> AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .auto:
            Self.exceedsH264HardwareCeiling(width: width, height: height, fps: fps) ? .hevc : .h264
        }
    }
}

/// How often the encoder is forced to emit a keyframe.
///
/// Task 064 item 3: an I-frame at 4K is far more expensive than a P-frame, so the
/// interval is a real lever on encoder throughput. It is also the recovery/robustness
/// knob — a truncated file loses at most one interval — so lengthening it is a genuine
/// trade-off against CLAUDE.md rule 1 and not a free win.
nonisolated enum KeyFrameInterval: Int, Codable, CaseIterable, Identifiable, Sendable {
    case oneSecond = 1
    case twoSeconds = 2
    case fourSeconds = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneSecond: "1초 (기본)"
        case .twoSeconds: "2초"
        case .fourSeconds: "4초"
        }
    }

    var shortTitle: String { "\(rawValue)s" }

    var detail: String {
        switch self {
        case .oneSecond: "가장 안전합니다. 파일이 잘려도 최대 1초만 손실됩니다."
        case .twoSeconds: "인코더 부하가 줄지만 손실 구간이 2초로 늘어납니다."
        case .fourSeconds: "부하가 가장 낮고 손실 구간이 4초로 늘어납니다."
        }
    }
}

/// The encoder-path settings Task 064 makes comparable. Bitrate is deliberately *not*
/// here — it already has one definition, `BitratePreset` feeding
/// `BitrateEstimationService`, and duplicating it would recreate exactly the
/// settings-divergence bug Task 049 removed.
nonisolated struct VideoEncoderSettings: Codable, Equatable, Sendable {
    var codec: VideoCodecPreference
    var keyFrameInterval: KeyFrameInterval

    static let `default` = VideoEncoderSettings(codec: .auto, keyFrameInterval: .oneSecond)
}
