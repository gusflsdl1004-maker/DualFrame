//
//  RecordingMode.swift
//  DualFrame
//

import Foundation

/// Whether a recording session produces one output or is intended to eventually
/// produce two (long-form + short-form) at once. `.dual` is not yet functional —
/// see `DualRecordingCoordinator` and `RecordingModeView` (Task 018: architecture only).
nonisolated enum RecordingMode: String, CaseIterable, Identifiable, Codable {
    case single
    case dual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "단일 녹화"
        case .dual: "듀얼 녹화"
        }
    }
}
