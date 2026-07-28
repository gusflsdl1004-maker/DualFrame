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

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// Moves a validated recording out of the temporary directory and into the
    /// permanent library, generating a unique, timestamp-based filename.
    @discardableResult
    func importRecording(
        from temporaryURL: URL,
        validation: RecordingValidationResult,
        createdAt: Date = Date()
    ) throws -> VideoRecord {
        let directory = try videosDirectory()
        let filename = uniqueFilename(for: createdAt, in: directory)
        let destinationURL = directory.appendingPathComponent(filename)

        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            throw InternalVideoLibraryError.importFailed
        }

        return VideoRecord(
            id: filename,
            filename: filename,
            createdAt: createdAt,
            duration: validation.duration,
            resolution: validation.resolution ?? .zero,
            fileSize: validation.fileSize,
            localURL: destinationURL
        )
    }

    /// Scans the library directory and reads each file's metadata.
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

    func delete(_ record: VideoRecord) throws {
        guard fileManager.fileExists(atPath: record.localURL.path) else {
            throw InternalVideoLibraryError.recordNotFound
        }
        try fileManager.removeItem(at: record.localURL)
    }

    /// Combines every persisted `RecordingGroup` (Task 023) with the library's actual
    /// `VideoRecord`s, resolving each group's references and never hiding a
    /// `VideoRecord` that no group happens to reference — those are surfaced as their
    /// own single-item group (Task 023 principle: existing files must never become
    /// invisible because of this feature). `loadAllRecords()` above is completely
    /// unaffected by this method — it's still the plain, ungrouped source of truth.
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
        resolved += orphanRecords.map { record in
            ResolvedRecordingGroup(
                id: "orphan-\(record.id)",
                createdAt: record.createdAt,
                recordingMode: .single,
                duration: record.duration,
                long: .succeeded(record),
                short: .none
            )
        }

        return resolved.sorted { $0.createdAt > $1.createdAt }
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

        return VideoRecord(
            id: url.lastPathComponent,
            filename: url.lastPathComponent,
            createdAt: createdAt,
            duration: duration,
            resolution: resolution ?? .zero,
            fileSize: fileSize,
            localURL: url
        )
    }
}
