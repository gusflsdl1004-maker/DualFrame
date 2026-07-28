//
//  RecordingGroup.swift
//  DualFrame
//

import Foundation

/// Whether one output (long-form or short-form) in a `RecordingGroup` succeeded — and
/// if so, which `VideoRecord` it refers to, by `id` only, never a copy of its data — or
/// failed. `nil` on `RecordingGroup.longRecording`/`shortRecording` means that slot
/// doesn't apply to this group at all (e.g. `.single` mode has no short-form slot).
nonisolated enum RecordingGroupMember: Codable, Equatable {
    case succeeded(videoRecordID: String)
    case failed
}

/// Groups the long-form and/or short-form outputs of one recording session for display
/// purposes (Task 023). Purely a reference layer over `VideoRecord` — it never
/// duplicates a `VideoRecord`'s data and never replaces it as the source of truth for
/// a video's existence (see CLAUDE.md's Task 023 principle). Built and persisted by
/// `RecordingViewModel` right after a recording finishes; read back by
/// `InternalVideoLibraryService.loadRecordingGroups(groupService:)`.
nonisolated struct RecordingGroup: Codable, Equatable, Identifiable {
    let id: String
    let createdAt: Date
    let recordingMode: RecordingMode
    let longRecording: RecordingGroupMember?
    let shortRecording: RecordingGroupMember?
    let duration: TimeInterval
}

/// One `RecordingGroup` member, resolved against the current library contents for
/// display. Never persisted — rebuilt fresh every time the library loads, so a
/// deleted or unmatched `VideoRecord` always degrades gracefully instead of crashing
/// or showing stale data.
nonisolated enum ResolvedRecordingGroupMember: Equatable {
    /// This slot doesn't apply to the group (e.g. a `.single`-mode group's short-form slot).
    case none
    /// The recording was attempted but failed — no `VideoRecord` was ever created for it.
    case failed
    /// The `RecordingGroup` references a `VideoRecord` `id` that can no longer be found
    /// in the library (e.g. it was deleted individually). The group itself is still
    /// shown — only this one slot degrades.
    case missing
    case succeeded(VideoRecord)
}

/// A `RecordingGroup` with its members resolved to actual `VideoRecord`s, ready for
/// display. See `InternalVideoLibraryService.loadRecordingGroups(groupService:)`.
nonisolated struct ResolvedRecordingGroup: Identifiable, Equatable {
    let id: String
    let createdAt: Date
    let recordingMode: RecordingMode
    let duration: TimeInterval
    let long: ResolvedRecordingGroupMember
    let short: ResolvedRecordingGroupMember
}
