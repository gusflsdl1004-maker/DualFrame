//
//  SelfTestResult.swift
//  DualFrame
//

import Foundation

/// The outcome of one Self Test check (Task 030). Not gated behind `#if DEBUG` itself
/// (it's an inert data type), but nothing outside `SelfTestService`/`SelfTestView`
/// (both Debug-only) ever constructs or reads one.
nonisolated enum SelfTestStatus: Equatable {
    case pass
    case warning(String)
    case fail(String)

    var label: String {
        switch self {
        case .pass: "PASS"
        case .warning: "WARNING"
        case .fail: "FAIL"
        }
    }

    var message: String? {
        switch self {
        case .pass: nil
        case .warning(let message), .fail(let message): message
        }
    }
}

nonisolated struct SelfTestItem: Identifiable, Equatable {
    let id: String
    let title: String
    let status: SelfTestStatus
    let detail: String?
}
