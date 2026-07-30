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

    /// Task 071: the record if this member actually produced one, `nil` otherwise.
    /// `ExportManager` uses this to resolve an `ExportTarget` into files — a target
    /// naming a member that failed, is missing, or was never produced resolves to
    /// nothing rather than silently exporting the other one.
    var record: VideoRecord? {
        if case .succeeded(let record) = self { return record }
        return nil
    }
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

    /// Task 042 requirement 3 (revised): what the Library should actually show for
    /// the short-form slot, given this group's output mode. Only `.longOnly` hides
    /// it — `.both`/`nil` (legacy) show it exactly as `short` already does. The
    /// long-form slot has no equivalent hiding case now that `.shortOnly` has been
    /// removed, so call sites use `long` directly.
    var displayedShort: ResolvedRecordingGroupMember {
        outputMode == .longOnly ? .none : short
    }
}
