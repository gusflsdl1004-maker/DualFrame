//
//  ExternalStorageService.swift
//  DualFrame
//

import Foundation

nonisolated enum ExternalStorageError: Error {
    case accessDenied
    case volumeInfoUnavailable
}

/// Connection state for the external storage feature. Distinct from `nil` on the
/// view model's device — `.unavailable` means a location was picked but couldn't
/// be read, `.disconnected` means nothing has been picked (or it was cleared).
nonisolated enum ExternalStorageStatus: Equatable {
    case connected
    case disconnected
    case unavailable
}

/// Detects and reads metadata for a user-selected external storage location
/// (e.g. a USB drive or SD card surfaced through the Files app / `UIDocumentPickerViewController`).
/// This only inspects the location — it never reads, writes, or copies any files there.
nonisolated struct ExternalStorageService {
    /// Reads volume metadata for a location the user picked via the Files picker.
    /// Manages the security-scoped access window itself for this single read.
    func makeDevice(from url: URL) throws -> ExternalStorageDevice {
        guard url.startAccessingSecurityScopedResource() else {
            throw ExternalStorageError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ])
        } catch {
            throw ExternalStorageError.volumeInfoUnavailable
        }

        let name = values.volumeName ?? url.lastPathComponent
        let availableSpace = values.volumeAvailableCapacityForImportantUsage ?? 0
        let totalSpace = Int64(values.volumeTotalCapacity ?? 0)

        return ExternalStorageDevice(
            id: url.path,
            name: name,
            path: url.path,
            isAvailable: true,
            availableSpace: availableSpace,
            totalSpace: totalSpace
        )
    }
}
