//
//  RecordingStartupEvent.swift
//  DualFrame
//

import Foundation

/// One entry in the recording startup timeline (Task 029 requirement 3) — e.g.
/// "Camera Configured", "Writer Created", "Recording", or an invalid-state-transition
/// warning. Purely descriptive; nothing reads these to make a decision anywhere in the
/// recording pipeline — they exist only for `RecordingDebugView` to display.
nonisolated struct RecordingStartupEvent: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let stage: String
    let detail: String?

    init(timestamp: Date = Date(), stage: String, detail: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.stage = stage
        self.detail = detail
    }
}
