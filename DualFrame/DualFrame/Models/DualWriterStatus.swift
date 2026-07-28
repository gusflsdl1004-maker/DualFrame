//
//  DualWriterStatus.swift
//  DualFrame
//

import Foundation

/// A point-in-time read of one `OutputProfile`'s writer — independent of every other
/// active writer, so a failure in one never has to be inferred from the others
/// (Task 019 requirement 6/8). `RecordingService` publishes one of these per active
/// `OutputProfile` via `writerStatuses`; the UI reads it to show Long/Short Recording
/// status separately.
nonisolated struct DualWriterStatus: Equatable {
    var state: RecordingState = .idle
    var lastError: RecordingError?
    var validationResult: RecordingValidationResult?
}
