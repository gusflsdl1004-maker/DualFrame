//
//  RecordingStartupFailureReason.swift
//  DualFrame
//

import Foundation

/// A more granular diagnosis of *why* a recording attempt reached `.failed` (Task 029
/// requirement 2) than the single generic message this app showed before. Deliberately
/// separate from `RecordingError` (defined in `RecordingValidator.swift`, which this
/// task must not modify) — `RecordingError` still drives the actual pipeline's
/// success/failure decisions unchanged; this enum exists purely to add diagnostic
/// detail on top, surfaced only in the debug panel.
nonisolated enum RecordingStartupFailureReason: Equatable {
    case writerCreationFailed
    case sessionNotPrepared
    case cameraUnavailable
    case audioUnavailable
    case invalidStateTransition
    case appendFailed
    case finishWritingFailed
    case unknown

    var description: String {
        switch self {
        case .writerCreationFailed: "Writer creation failed"
        case .sessionNotPrepared: "Session not prepared"
        case .cameraUnavailable: "Camera unavailable"
        case .audioUnavailable: "Audio unavailable"
        case .invalidStateTransition: "Invalid state transition"
        case .appendFailed: "Append failed"
        case .finishWritingFailed: "finishWriting failed"
        case .unknown: "Unknown"
        }
    }
}
