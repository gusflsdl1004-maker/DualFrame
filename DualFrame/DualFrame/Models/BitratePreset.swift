//
//  BitratePreset.swift
//  DualFrame
//

import Foundation

/// Task 050 requirement 3: the user-facing recording quality preset. Scales the
/// per-resolution bitrate `BitrateEstimationService` computes, rather than replacing it
/// — so the resolution/FPS tiering stays in one place and a preset only says "more or
/// fewer bits for the same frame".
///
/// The multipliers are applied to the `.high` baseline, which is the bitrate Task 049
/// established (4K60 ≈ 100 Mbps for H.264). `.standard` trades some detail for smaller
/// files and less encoder load; `.maximum` is for when quality matters more than either.
nonisolated enum BitratePreset: String, CaseIterable, Identifiable, Codable {
    case standard
    case high
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "표준"
        case .high: "고화질"
        case .maximum: "최고화질"
        }
    }

    /// Short form for the recording HUD, where horizontal space is tight.
    var shortTitle: String { title }

    var detail: String {
        switch self {
        case .standard: "파일이 작고 발열이 적습니다."
        case .high: "권장. 화질과 파일 크기의 균형."
        case .maximum: "화질 우선. 파일이 크고 발열이 늘어납니다."
        }
    }

    /// Multiplier on the resolution/FPS bitrate. `.high` is the 1.0 baseline.
    var bitrateMultiplier: Double {
        switch self {
        case .standard: 0.7
        case .high: 1.0
        case .maximum: 1.4
        }
    }
}

/// The user's persisted preset. Mirrors `RecordingQualitySettings`.
nonisolated struct BitratePresetSettings: Codable, Equatable {
    var preset: BitratePreset

    static let `default` = BitratePresetSettings(preset: .high)
}
