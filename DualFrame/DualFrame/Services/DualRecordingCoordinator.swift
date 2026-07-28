//
//  DualRecordingCoordinator.swift
//  DualFrame
//

import Foundation

/// Decides which `OutputProfile`s a recording session should target for the current
/// `RecordingMode`, and is the future home of dual-output orchestration.
///
/// Today this coordinator does not drive any recording by itself — `RecordingModeView`
/// keeps `.dual` disabled and unselectable, and nothing here ever starts a second
/// `RecordingService` or `AVAssetWriter` (requirements 10, 11, 12). It exists purely as
/// the architectural seam a future task would extend:
///
/// - `mode` would gate which of `activeProfiles` are actually recorded.
/// - Each active `OutputProfile` would need its own writer pipeline (see the
///   `WriterContext` extension point documented in `RecordingService`), started and
///   stopped together.
/// - Requirement 41 (CLAUDE.md rule 41): those pipelines must share a single timing
///   reference — e.g. the same `recordingStartTime` and sample buffer source — so the
///   long-form and short-form outputs stay in sync. Nothing here implements that yet;
///   it is documented so the eventual design doesn't drift from it.
///
/// An `actor` because a future implementation will coordinate multiple concurrently
/// running writer pipelines, which needs the same isolation guarantees `RecordingService`
/// already relies on.
actor DualRecordingCoordinator {
    private(set) var mode: RecordingMode

    /// The one pipeline every mode currently uses. Rule 39/40: this is intentionally
    /// the *same* `RecordingService` instance the rest of the app already drives — dual
    /// recording must not duplicate recording logic, only attach additional outputs to
    /// this existing flow in a future task.
    let recordingService: RecordingService

    init(mode: RecordingMode, recordingService: RecordingService) {
        self.mode = mode
        self.recordingService = recordingService
    }

    func setMode(_ mode: RecordingMode) {
        self.mode = mode
    }

    /// The output(s) intended for the current mode. Lists both profiles under `.dual`
    /// to document the intended mapping even though only `.longForm` is ever actually
    /// recorded today — `.dual` cannot currently be selected from the UI.
    var activeProfiles: [OutputProfile] {
        switch mode {
        case .single:
            [.longForm]
        case .dual:
            [.longForm, .shortForm]
        }
    }
}
