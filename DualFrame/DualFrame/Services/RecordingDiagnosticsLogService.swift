//
//  RecordingDiagnosticsLogService.swift
//  DualFrame
//

import Foundation

/// A crash-safe, in-memory ring buffer of the last 30 recording startup events (Task
/// 029 requirement 3), written to by both `RecordingService` and `CameraService`.
///
/// `log(_:detail:)` cannot throw and cannot meaningfully fail — it only appends to an
/// array — but every caller still fires it via a detached `Task { await ... }` rather
/// than an inline `await`, so a slow or misbehaving logging call can never add latency
/// to the actual capture/write path (requirement 5: diagnostics must never be able to
/// interrupt or delay a recording). This is purely observational — nothing in the
/// recording pipeline ever reads this service to make a decision.
actor RecordingDiagnosticsLogService {
    private(set) var events: [RecordingStartupEvent] = []
    private let maxEvents = 30

    func log(_ stage: String, detail: String? = nil) {
        events.append(RecordingStartupEvent(stage: stage, detail: detail))
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    /// Newest last, matching how the events were recorded — the debug view reverses
    /// this for display if it wants newest-first.
    func recentEvents() -> [RecordingStartupEvent] {
        events
    }
}
