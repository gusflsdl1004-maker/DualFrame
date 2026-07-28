//
//  DualRecordingCoordinator.swift
//  DualFrame
//

import Foundation

/// Tracks which `RecordingMode` the app is currently set to and which `OutputProfile`s
/// that implies, kept in sync with `RecordingModeSettingsService` by
/// `RecordingViewModel.startRecording()` on every recording start (rule 39: a single
/// place decides mode → profile mapping, rather than duplicating it).
///
/// The actual dual-writer engine — independent `AVAssetWriter`s per profile, shared
/// timing, independent failure handling — lives in `RecordingService` as of Task 019
/// (see its `WriterContext`/`writerContexts` documentation). This coordinator does not
/// drive any of that itself; it wraps a reference to the same `RecordingService`
/// instance the rest of the app already uses (rule 39/40: never a second, duplicate
/// pipeline) and exists so callers that only need "what mode / what profiles" don't
/// have to reach into the recording actor's internals.
///
/// An `actor` because `RecordingService` (which it references) is one, and because a
/// future feature (e.g. a Settings screen listing both outputs' profiles live) may read
/// `activeProfiles` concurrently with a recording in progress.
actor DualRecordingCoordinator {
    private(set) var mode: RecordingMode

    /// The `RecordingService` instance this coordinator's mode applies to. Always the
    /// same instance `CameraPreviewView` wires everywhere else.
    let recordingService: RecordingService

    init(mode: RecordingMode, recordingService: RecordingService) {
        self.mode = mode
        self.recordingService = recordingService
    }

    func setMode(_ mode: RecordingMode) {
        self.mode = mode
    }

    /// The output(s) intended for the current mode. `RecordingService.targetProfiles`
    /// mirrors this exact mapping internally — kept as two separate small switch
    /// statements rather than a shared dependency, since inlining it avoids an actor
    /// hop from the hot recording path for a two-case lookup.
    var activeProfiles: [OutputProfile] {
        switch mode {
        case .single:
            [.longForm]
        case .dual:
            [.longForm, .shortForm]
        }
    }
}
