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
    /// Task 042: the user-facing output mode this session was recorded under.
    /// Optional — and Swift's synthesized `Decodable` conformance treats a missing key
    /// as `nil` for an `Optional` property — so every `RecordingGroup` persisted
    /// before this task still decodes exactly as it always has (requirement 8: no
    /// migration). `nil` means "made before Task 042, show everything" everywhere
    /// this is read.
    let outputMode: RecordingOutputMode?
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
    /// Task 042: `nil` for groups made before Task 042 (or by the legacy heuristic,
    /// which has no reliable way to know) — display code treats `nil` the same as
    /// `.both` (show everything), so old groups are completely unaffected.
    let outputMode: RecordingOutputMode?

    /// Task 042 requirement 7: what the Library should actually show for the long-form
    /// slot, given this group's output mode. Only hides the slot for `.shortOnly` —
    /// `.longOnly`/`.both`/`nil` (legacy) show it exactly as `long` already does.
    ///
    /// Known limitation (see the Task 042 report): `.shortOnly` currently still
    /// records a real long-form file under the hood (`RecordingOutputMode
    /// .underlyingRecordingMode` maps it to `.dual`, since `RecordingService` has no
    /// real short-only capability yet) — this only hides it from this display, the
    /// file itself still exists in the library and still consumes storage.
    var displayedLong: ResolvedRecordingGroupMember {
        outputMode == .shortOnly ? .none : long
    }

    /// Same reasoning as `displayedLong`, for the short-form slot — only `.longOnly`
    /// hides it.
    var displayedShort: ResolvedRecordingGroupMember {
        outputMode == .longOnly ? .none : short
    }
}
