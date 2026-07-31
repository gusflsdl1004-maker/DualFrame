//
//  ShortGenerationQuality.swift
//  DualFrame
//

import Foundation

/// How the short-form output should be generated.
///
/// Task 074 P2: structure only. Both cases are selectable today so the plumbing is real
/// rather than hypothetical, but `.fast` is what makes this worth having — the
/// post-processing pass currently runs at roughly 0.6× real time on a 4K60 source, and
/// halving the output frame rate halves the encoder's work.
///
/// Deliberately **not** gated on `UserPlan` here. `ExportManager` is the only type in the
/// app that reads the plan (Task 071 requirement 7), and generation must keep working
/// identically for free and Pro users — a monetisation check inside the generation path
/// is exactly the coupling that rule exists to prevent. When "Pro chooses 최고 화질"
/// ships, the gate belongs at the settings screen that writes this value, not here.
nonisolated enum ShortGenerationQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 1080×1920 @ 30fps. Half the frames to encode.
    case fast
    /// 1080×1920 at the source's frame rate — what every generation has done so far.
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: "빠른 생성 (30fps)"
        case .maximum: "최고 화질 (원본 FPS)"
        }
    }

    var detail: String {
        switch self {
        case .fast: "생성 시간이 크게 줄어듭니다. 쇼츠 플랫폼은 대부분 30fps로 재생됩니다."
        case .maximum: "원본과 같은 프레임레이트를 유지합니다. 생성이 오래 걸립니다."
        }
    }

    /// The frame rate the generated file should target, given what the source was
    /// recorded at. `.fast` never *raises* the rate — a 30fps recording stays 30fps.
    func outputFPS(sourceFPS: RecordingFPS) -> RecordingFPS {
        switch self {
        case .maximum: sourceFPS
        case .fast: sourceFPS.rawValue > 30 ? .fps30 : sourceFPS
        }
    }
}

nonisolated struct ShortGenerationQualitySettings: Codable, Equatable, Sendable {
    var quality: ShortGenerationQuality

    /// Defaults to `.maximum` — the behaviour every existing recording already got.
    /// Changing what users silently receive is not something to slip into a structural
    /// task (CLAUDE.md rule 47).
    static let `default` = ShortGenerationQualitySettings(quality: .maximum)
}
