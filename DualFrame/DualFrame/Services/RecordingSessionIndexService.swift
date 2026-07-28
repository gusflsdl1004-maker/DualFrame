//
//  RecordingSessionIndexService.swift
//  DualFrame
//

import Foundation

/// Extension point (Task 025 requirement 6) — not implemented, and not wired into
/// anything. Not implemented.
///
/// Today, finding a session's `VideoRecord`s
/// (`RecordingViewModel.recordGroup`, `InternalVideoLibraryService.loadRecordingGroups`)
/// means scanning every file in the library and reading its `VideoRecordMetadata`
/// sidecar to check its `sessionID` — an `O(n)` scan per lookup. Fine at today's
/// library sizes; would not scale indefinitely.
///
/// A future implementation would maintain a persisted `[UUID: [String]]` map
/// (`sessionID` -> video record ids), updated incrementally by
/// `InternalVideoLibraryService.importRecording`/`delete` so it never has to be
/// rebuilt from scratch, and consulted first for an `O(1)` lookup — falling back to a
/// full scan whenever the index is missing, stale, or fails to load, so a broken or
/// out-of-date index can only ever cost performance, never correctness.
///
/// TODO: implement index storage (mirroring `RecordingGroupService`'s JSON-per-entity
/// pattern, or a single JSON map file — undecided), incremental updates, and the
/// fallback-to-full-scan behavior described above. Wire it into
/// `InternalVideoLibraryService` only once all three exist together.
actor RecordingSessionIndexService {
    // Intentionally empty — see the type-level doc comment. Nothing here is called by
    // any other code yet.
}
