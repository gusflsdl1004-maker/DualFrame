//
//  InternalVideoLibraryService.swift
//  DualFrame
//

import AVFoundation

/// Errors from moving, scanning, or deleting recordings in the internal library.
nonisolated enum InternalVideoLibraryError: Error {
    case directoryUnavailable
    case importFailed
    case recordNotFound
}

/// Owns the app's permanent, on-disk video library at
/// `Application Support/DualFrame/Videos/` — separate from the temporary directory
/// `RecordingService` writes to while recording.
///
/// No Photos saving, export, or external storage happens here.
actor InternalVideoLibraryService {
    private let fileManager = FileManager.default
    private let metadataService: VideoRecordMetadataService

    /// Task 025: every recording session currently active, keyed by `sessionID`. Was a
    /// single `RecordingSessionMetadata?` in Task 024 — restructured into a dictionary
    /// as a foundation for future Resume/Background Recording work, where more than one
    /// session could plausibly be pending at once (e.g. a backgrounded recording still
    /// finishing its import while a new one starts). Every `importRecording(...)` call
    /// tags its resulting `VideoRecord` with a pending session's `sessionID` — this is
    /// how `RecordingService` (which this task must not modify) ends up producing
    /// sessionID-tagged files without ever knowing sessions exist: its existing,
    /// unchanged `importRecording` call just runs while an entry is present here.
    ///
    /// Today the app only ever runs one recording at a time (see
    /// `RecordingViewModel`), so this dictionary holds at most one entry in practice —
    /// `currentSessionForImport()` reflects that reality honestly rather than
    /// pretending to disambiguate between sessions it has no way to distinguish yet.
    private var pendingSessions: [UUID: RecordingSessionMetadata] = [:]

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    init(metadataService: VideoRecordMetadataService = VideoRecordMetadataService()) {
        self.metadataService = metadataService
    }

    /// Task 024 requirement 2, Task 025 requirement 1: called by
    /// `RecordingViewModel.startRecording()` right before a recording begins. Adds
    /// `metadata` to `pendingSessions`; every `importRecording` call until
    /// `endSession(_:)` removes it is tagged with `metadata.sessionID`.
    func beginSession(_ metadata: RecordingSessionMetadata) {
        pendingSessions[metadata.sessionID] = metadata
    }

    /// Removes one session from `pendingSessions` by id. Task 025 requirement 2:
    /// `RecordingViewModel` calls this on *every* exit path from a recording attempt —
    /// not just a clean finish — so a failed `prepareRecording()`, a failed
    /// `startRecording()`, or the user cancelling before recording truly begins can
    /// never leave a stale entry here. See `RecordingViewModel.endCurrentSession()`.
    func endSession(_ sessionID: UUID) {
        pendingSessions.removeValue(forKey: sessionID)
    }

    /// The session `importRecording` should tag a just-imported file with. Task 025
    /// requirement 1: looks up `pendingSessions` rather than a single ambient value —
    /// today there is always at most one entry (this app never runs two recordings at
    /// once), so this is equivalent in behavior to Task 024's single-value version, but
    /// the lookup itself no longer assumes that will always be true.
    private func currentSessionForImport() -> RecordingSessionMetadata? {
        pendingSessions.values.first
    }

    /// Moves a validated recording out of the temporary directory and into the
    /// permanent library, generating a unique, timestamp-based filename. Tags the
    /// resulting `VideoRecord` with the active session's `sessionID`/`outputProfile`,
    /// if `beginSession(_:)` was called (Task 024) — untagged (both `nil`) otherwise,
    /// same as every recording made before Task 024 existed.
    @discardableResult
    func importRecording(
        from temporaryURL: URL,
        validation: RecordingValidationResult,
        createdAt: Date = Date()
    ) async throws -> VideoRecord {
        let directory = try videosDirectory()
        let filename = uniqueFilename(for: createdAt, in: directory)
        let destinationURL = directory.appendingPathComponent(filename)

        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            throw InternalVideoLibraryError.importFailed
        }

        var sessionID: UUID?
        var outputProfile: OutputProfile?
        if let session = currentSessionForImport() {
            // TODO(Extension point, Task 025 requirement 3): this resolution-based
            // match is still an inference, not an identifier — `RecordingService`
            // knows exactly which `OutputProfile` it's writing for at the moment it
            // calls `libraryService.importRecording(...)`, but its call site must not
            // be modified by this task. A future task could add an
            // `outputProfile: OutputProfile? = nil` parameter to `importRecording`
            // (default keeps every existing call site — including RecordingService's —
            // source-compatible) and have `RecordingService` pass its own profile
            // directly; this method would then prefer that parameter over
            // `matchProfile` whenever it's non-nil, and the resolution-based inference
            // below could eventually be deleted entirely once nothing needs it.
            let profile = Self.matchProfile(resolution: validation.resolution, among: Self.expectedProfiles(for: session))
            sessionID = session.sessionID
            outputProfile = profile
            if let profile {
                let metadata = VideoRecordMetadata(videoRecordID: filename, sessionID: session.sessionID, outputProfile: profile)
                await metadataService.save(metadata)
            }
        }

        return VideoRecord(
            id: filename,
            filename: filename,
            createdAt: createdAt,
            duration: validation.duration,
            resolution: validation.resolution ?? .zero,
            fileSize: validation.fileSize,
            localURL: destinationURL,
            sessionID: sessionID,
            outputProfile: outputProfile
        )
    }

    /// Scans the library directory and reads each file's metadata. Unchanged in shape
    /// since before Task 023 — still the plain, ungrouped source of truth every other
    /// method here builds on.
    func loadAllRecords() async throws -> [VideoRecord] {
        let directory = try videosDirectory()
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var records: [VideoRecord] = []
        for url in fileURLs {
            if let record = await makeRecord(from: url) {
                records.append(record)
            }
        }
        return records
    }

    /// Deletion order (Task 025 requirement 4, documented explicitly since two more
    /// layers of metadata now hang off one `VideoRecord`):
    /// 1. **Video file** — removed first, and only this step can throw. If it fails,
    ///    nothing else runs, so metadata is never deleted out from under a video that's
    ///    still actually there.
    /// 2. **`VideoRecordMetadata` sidecar** (this method) — best-effort, via
    ///    `VideoRecordMetadataService.delete`, which already swallows its own errors
    ///    and never throws. If it fails (e.g. the sidecar file was already gone), the
    ///    video deletion above is **not** undone — a missing sidecar just means the
    ///    next `loadAllRecords()` sees `sessionID`/`outputProfile` as `nil` for nothing,
    ///    since the video itself is gone too. This can never crash the app.
    /// 3. **`RecordingGroup`** — one layer up, in
    ///    `VideoLibraryViewModel.delete(_ group:)`, which deletes every member's
    ///    `VideoRecord` (steps 1-2, per member) and only then removes the group's own
    ///    JSON via `RecordingGroupService.delete(id:)`. Not this method's concern —
    ///    documented here so the full chain is traceable from one place.
    func delete(_ record: VideoRecord) async throws {
        guard fileManager.fileExists(atPath: record.localURL.path) else {
            throw InternalVideoLibraryError.recordNotFound
        }
        try fileManager.removeItem(at: record.localURL)
        await metadataService.delete(videoRecordID: record.id)
    }

    /// Combines every persisted `RecordingGroup` with the library's actual
    /// `VideoRecord`s, resolving each group's references and never hiding a
    /// `VideoRecord` that no group happens to reference — those are surfaced as their
    /// own single-item group. `loadAllRecords()` above is completely unaffected by this
    /// method — it's still the plain, ungrouped source of truth.
    func loadRecordingGroups(groupService: RecordingGroupService) async throws -> [ResolvedRecordingGroup] {
        let records = try await loadAllRecords()
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let groups = await groupService.loadAll()

        var referencedIDs = Set<String>()
        func resolve(_ member: RecordingGroupMember?) -> ResolvedRecordingGroupMember {
            switch member {
            case nil:
                return .none
            case .failed:
                return .failed
            case .succeeded(let id):
                guard let record = recordsByID[id] else { return .missing }
                referencedIDs.insert(id)
                return .succeeded(record)
            }
        }

        var resolved = groups.map { group in
            ResolvedRecordingGroup(
                id: group.id,
                createdAt: group.createdAt,
                recordingMode: group.recordingMode,
                duration: group.duration,
                long: resolve(group.longRecording),
                short: resolve(group.shortRecording)
            )
        }

        let orphanRecords = records.filter { !referencedIDs.contains($0.id) }

        // Task 024 requirement 7: a `VideoRecord` that already carries a `sessionID`
        // was made under this task's regime — if it's still orphaned (no persisted
        // group referenced it), that's unexpected, but it must never be guessed into a
        // pairing via the legacy heuristic. Shown standalone instead.
        let taggedOrphans = orphanRecords.filter { $0.sessionID != nil }
        resolved += taggedOrphans.map { record in
            ResolvedRecordingGroup(
                id: "orphan-\(record.id)",
                createdAt: record.createdAt,
                recordingMode: .single,
                duration: record.duration,
                long: .succeeded(record),
                short: .none
            )
        }

        // Task 024 requirement 7: only recordings made before Task 024 (no sessionID
        // at all) fall back to the Task 023 time/aspect-ratio heuristic.
        let legacyOrphans = orphanRecords.filter { $0.sessionID == nil }
        resolved += Self.groupLegacyOrphans(legacyOrphans)

        return resolved.sorted { $0.createdAt > $1.createdAt }
    }

    /// The `OutputProfile`(s) a session with `metadata`'s mode/quality/FPS could have
    /// produced — mirrors exactly what `RecordingService.targetProfiles` computes
    /// internally (that type must not be modified, so this is a separate, matching
    /// implementation, not a shared one). Used only to tag a *just-imported* file
    /// (requirement: no cross-file, cross-time guessing) — see `matchProfile`.
    private static func expectedProfiles(for metadata: RecordingSessionMetadata) -> [OutputProfile] {
        switch metadata.recordingMode {
        case .single:
            let dimensions = metadata.selectedQuality.dimensions
            return [OutputProfile(
                outputName: "Single",
                resolution: OutputResolution(width: dimensions.width, height: dimensions.height),
                fps: metadata.selectedFPS,
                aspectRatio: .widescreen
            )]
        case .dual:
            return [.longForm, .shortForm]
        }
    }

    /// Matches a just-imported file's resolution against the (at most two) profiles a
    /// session could have produced, by aspect ratio. Deterministic in practice — unlike
    /// the Task 023 heuristic, this never searches beyond the current session's own,
    /// already-known candidate set.
    private static func matchProfile(resolution: CGSize?, among profiles: [OutputProfile]) -> OutputProfile? {
        guard let resolution else { return profiles.first }
        let isPortrait = resolution.height > resolution.width
        return profiles.first(where: { ($0.aspectRatio == .vertical) == isPortrait }) ?? profiles.first
    }

    /// Task 023's original time/aspect-ratio heuristic, kept ONLY as a fallback for
    /// recordings made before Task 024 introduced `sessionID` (requirement 7) — never
    /// applied to anything that carries a `sessionID`.
    private static func groupLegacyOrphans(_ records: [VideoRecord]) -> [ResolvedRecordingGroup] {
        var candidates = records.sorted { $0.createdAt < $1.createdAt }
        var groups: [ResolvedRecordingGroup] = []

        while !candidates.isEmpty {
            let record = candidates.removeFirst()
            let isPortrait = record.resolution.height > record.resolution.width

            if let pairIndex = candidates.firstIndex(where: {
                abs($0.createdAt.timeIntervalSince(record.createdAt)) <= 10
                    && ($0.resolution.height > $0.resolution.width) != isPortrait
            }) {
                let pair = candidates.remove(at: pairIndex)
                let long = isPortrait ? pair : record
                let short = isPortrait ? record : pair
                groups.append(ResolvedRecordingGroup(
                    id: "legacy-\(long.id)-\(short.id)",
                    createdAt: min(long.createdAt, short.createdAt),
                    recordingMode: .dual,
                    duration: long.duration,
                    long: .succeeded(long),
                    short: .succeeded(short)
                ))
            } else {
                groups.append(ResolvedRecordingGroup(
                    id: "legacy-\(record.id)",
                    createdAt: record.createdAt,
                    recordingMode: .single,
                    duration: record.duration,
                    long: .succeeded(record),
                    short: .none
                ))
            }
        }
        return groups
    }

    private func videosDirectory() throws -> URL {
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw InternalVideoLibraryError.directoryUnavailable
        }

        let directory = appSupport
            .appendingPathComponent("DualFrame", isDirectory: true)
            .appendingPathComponent("Videos", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func uniqueFilename(for date: Date, in directory: URL) -> String {
        let base = Self.filenameFormatter.string(from: date)
        var candidate = "\(base).mov"
        var suffix = 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)_\(suffix).mov"
            suffix += 1
        }
        return candidate
    }

    private func makeRecord(from url: URL) async -> VideoRecord? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let fileSize = attributes[.size] as? Int64 ?? 0
        let createdAt = attributes[.creationDate] as? Date ?? Date()

        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              let tracks = try? await asset.load(.tracks) else {
            return nil
        }
        let videoTrack = tracks.first { $0.mediaType == .video }
        let resolution = (try? await videoTrack?.load(.naturalSize)) ?? nil

        let id = url.lastPathComponent
        let metadata = await metadataService.load(videoRecordID: id)

        return VideoRecord(
            id: id,
            filename: id,
            createdAt: createdAt,
            duration: duration,
            resolution: resolution ?? .zero,
            fileSize: fileSize,
            localURL: url,
            sessionID: metadata?.sessionID,
            outputProfile: metadata?.outputProfile
        )
    }
}
