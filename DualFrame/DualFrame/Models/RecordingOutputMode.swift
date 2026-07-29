//
//  RecordingOutputMode.swift
//  DualFrame
//

import Foundation

/// Task 042 (revised): the user-facing choice of what to save — replaces "Single
/// Recording" / "Dual Recording" everywhere a person actually sees it. Users never
/// need to understand `RecordingMode`/Single-vs-Dual at all; they only ever see one
/// of these two options.
///
/// A third case, `.shortOnly`, existed in the original Task 042 implementation but
/// was removed before merge: `RecordingService` has no real short-only capability,
/// so a "Short만 저장" recording would have actually written both Long and Short
/// files while only hiding Long in the Library — presenting the user with a choice
/// that lied about what it did. It will come back once `RecordingService` gains
/// genuine short-only support.
///
/// `RecordingMode` itself is kept exactly as-is for internal use (requirement 2) —
/// `RecordingService`/`DualRecordingCoordinator` still only know `.single`/`.dual`,
/// unchanged. `underlyingRecordingMode` is the one place that translates a user's
/// choice into what the untouched pipeline actually understands.
nonisolated enum RecordingOutputMode: String, CaseIterable, Identifiable, Codable {
    case longOnly
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .longOnly: "Long만 저장"
        case .both: "Long + Short 저장"
        }
    }

    var underlyingRecordingMode: RecordingMode {
        switch self {
        case .longOnly: .single
        case .both: .dual
        }
    }
}
