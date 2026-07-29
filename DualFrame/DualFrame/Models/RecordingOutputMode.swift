//
//  RecordingOutputMode.swift
//  DualFrame
//

import Foundation

/// Task 042: the user-facing choice of what to save — replaces "Single Recording" /
/// "Dual Recording" everywhere a person actually sees it. Users never need to
/// understand `RecordingMode`/Single-vs-Dual at all; they only ever see one of these
/// three options.
///
/// `RecordingMode` itself is kept exactly as-is for internal use (requirement 2) —
/// `RecordingService`/`DualRecordingCoordinator` still only know `.single`/`.dual`,
/// unchanged. `underlyingRecordingMode` is the one place that translates a user's
/// choice into what the untouched pipeline actually understands.
nonisolated enum RecordingOutputMode: String, CaseIterable, Identifiable, Codable {
    case longOnly
    case shortOnly
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .longOnly: "Long만 저장"
        case .shortOnly: "Short만 저장"
        case .both: "Long + Short 저장"
        }
    }

    /// Requirement 4: this task only prepares the structure — the actual recording
    /// pipeline (`RecordingService`) still only has two real behaviors
    /// (`.single`: one ad-hoc-profile output; `.dual`: both fixed-profile outputs
    /// together). `.shortOnly` has no real counterpart yet, so it maps to `.dual` as a
    /// placeholder — a "Short만 저장" recording today actually still writes *both*
    /// Long and Short files under the hood; only the Library display (Task 042
    /// requirement 7) hides the Long side. See the Task 042 report's Known Issues.
    var underlyingRecordingMode: RecordingMode {
        switch self {
        case .longOnly: .single
        case .shortOnly: .dual
        case .both: .dual
        }
    }
}
