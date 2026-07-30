//
//  UserPlan.swift
//  DualFrame
//

import Foundation

/// Whether the user has paid. Task 071: the **only** thing in the app that branches on
/// this is `ExportManager` — recording, generation and the library are all plan-blind by
/// design (requirement 7).
nonisolated enum UserPlan: String, Codable, CaseIterable, Identifiable, Sendable {
    case free
    case pro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "무료"
        case .pro: "Pro"
        }
    }

    /// Free users watch a rewarded ad before an export reaches the camera roll; Pro
    /// exports immediately.
    var requiresRewardedAdForExport: Bool { self == .free }
}

/// What the mock ad should do next. Exists so the branch that **refuses to save** can
/// actually be exercised — a mock that always rewards leaves the most consequential
/// path in this feature untested until a real SDK arrives.
nonisolated enum MockAdOutcome: String, Codable, CaseIterable, Identifiable, Sendable {
    case reward
    case dismissEarly
    case fail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reward: "정상 지급"
        case .dismissEarly: "도중 닫기"
        case .fail: "로드 실패"
        }
    }
}

nonisolated struct UserPlanSettings: Codable, Equatable, Sendable {
    var plan: UserPlan
    /// Test-only, and only consulted by `MockRewardedAdService`. A real SDK ignores it.
    /// Optional so settings written before this field still decode.
    var mockAdOutcome: MockAdOutcome?

    static let `default` = UserPlanSettings(plan: .free, mockAdOutcome: .reward)
}

/// What the user asked to export. Requirement 5.
///
/// `.longAndShort` is one user action, not two — it either exports both or reports which
/// half failed, and a free user watches **one** ad for it rather than one per file.
nonisolated enum ExportTarget: String, CaseIterable, Identifiable, Sendable {
    case longOnly
    case shortOnly
    case longAndShort

    var id: String { rawValue }

    var title: String {
        switch self {
        case .longOnly: "롱폼만 저장"
        case .shortOnly: "숏폼만 저장"
        case .longAndShort: "롱폼 + 숏폼 저장"
        }
    }
}
