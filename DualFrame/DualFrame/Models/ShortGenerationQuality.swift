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
    /// 1080×1920 @ 30fps. The only mode.
    ///
    /// Task 076 #4: the 60fps option is **removed**, not merely defaulted away from.
    /// Generation runs at roughly 0.6× real time on a 4K60 source, and 60fps doubled
    /// the encoder's work for frames the short-form platforms play back at 30 anyway.
    /// Keeping it as a switch would keep a path that is slow by construction, and the
    /// point of this policy is that nobody waits twice as long for nothing.
    ///
    /// The enum survives as a single case on purpose: `ShortGenerationMetrics` records
    /// it, so historical diagnostics still decode, and a future option (a different
    /// aspect ratio, an Auto Reframe mode) has somewhere to go.
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: "빠름"
        }
    }

    /// Shown next to the picker and in the generation banner, so the user knows which
    /// trade-off produced the wait they are looking at.
    var subtitle: String {
        switch self {
        case .fast: "FHD · 30fps"
        }
    }

    var detail: String {
        switch self {
        case .fast: "쇼츠는 항상 FHD 30fps로 생성됩니다. 생성 시간이 가장 짧고 대부분의 SNS 업로드에 적합합니다."
        }
    }

    /// Task 075 item 6. Deliberately a range and deliberately vague for `.maximum` —
    /// the only measured figure this project has is ~5 minutes for a 3.15GB 4K60 source,
    /// and quoting a number derived from one unmeasured configuration would be inventing
    /// data. Tighten these once the Task 073 per-stage measurement exists.
    var estimatedDurationText: String {
        switch self {
        case .fast: "예상 생성시간 약 20~40초"
        }
    }

    /// The frame rate the generated file should target, given what the source was
    /// recorded at. `.fast` never *raises* the rate — a 30fps recording stays 30fps.
    func outputFPS(sourceFPS: RecordingFPS) -> RecordingFPS {
        // Never *raises* the rate — a 30fps recording stays 30fps rather than being
        // interpolated up to something the source never contained.
        sourceFPS.rawValue > 30 ? .fps30 : sourceFPS
    }
}

nonisolated struct ShortGenerationQualitySettings: Codable, Equatable, Sendable {
    var quality: ShortGenerationQuality

    /// Task 075 item 4: **`.fast` is now the default.**
    ///
    /// The policy this implements: 60fps belongs to the long-form recording, which is
    /// the thing worth keeping at maximum quality. The short-form output exists to be
    /// posted, and every major platform plays it back at 30fps — so paying twice the
    /// encode time for frames nobody sees is a bad trade against the wait it creates.
    static let `default` = ShortGenerationQualitySettings(quality: .fast)
}
