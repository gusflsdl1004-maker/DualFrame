//
//  StorageEstimationService.swift
//  DualFrame
//

import Foundation

/// Task 041: queries the device's total/used/available storage. Deliberately
/// independent of `RecordingPerformanceMonitor.currentAvailableStorageBytes()` (which
/// is scoped to an active `RecordingService`) — this needs to work continuously,
/// before, during, and after a recording, without depending on the recording actor at
/// all. Same underlying `URLResourceValues` query, just not coupled to a session.
nonisolated struct StorageEstimationService {
    nonisolated struct StorageSnapshot: Equatable {
        let totalBytes: Int64
        let availableBytes: Int64
        var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    }

    /// Requirement 1: total/used/available storage. `nil` if the volume query fails
    /// (e.g. an unexpected `FileManager` error) — callers treat that like "unknown,"
    /// never like "zero space left."
    func currentSnapshot(directory: URL = FileManager.default.temporaryDirectory) -> StorageSnapshot? {
        guard let values = try? directory.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else {
            return nil
        }
        guard let totalCapacity = values.volumeTotalCapacity,
              let availableCapacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return StorageSnapshot(totalBytes: Int64(totalCapacity), availableBytes: availableCapacity)
    }
}
