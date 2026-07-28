//
//  RecoveryViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// What the Recovery Status section in Settings should show. `.corrupted` and
/// `.checking` exist alongside the two states Task 016 asks for (Recovery Available /
/// No Recovery Needed) so a broken checkpoint is reported rather than silently ignored
/// or mistaken for "nothing to recover" (CLAUDE.md rule 28).
nonisolated enum RecoveryStatus: Equatable {
    case checking
    case recoveryAvailable
    case noRecoveryNeeded
    case corrupted
}

/// Detects whether a leftover recording checkpoint exists — e.g. from a crash or
/// force-quit during a previous recording — and reports it. This never recovers or
/// deletes anything itself (requirement 16); it only reads and displays.
@MainActor
final class RecoveryViewModel: ObservableObject {
    @Published private(set) var status: RecoveryStatus = .checking
    @Published private(set) var checkpoint: RecordingCheckpoint?
    @Published private(set) var temporaryFileExists = false

    private let checkpointStore: RecordingCheckpointStore
    private let integrityValidator: FileIntegrityValidator

    var formattedTimestamp: String {
        guard let checkpoint else { return "--" }
        return checkpoint.recordingStartTime.formatted(date: .abbreviated, time: .shortened)
    }

    var formattedDuration: String {
        guard let checkpoint else { return "--" }
        let totalSeconds = Int(checkpoint.recordingDuration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    init(
        checkpointStore: RecordingCheckpointStore,
        integrityValidator: FileIntegrityValidator = FileIntegrityValidator()
    ) {
        self.checkpointStore = checkpointStore
        self.integrityValidator = integrityValidator
    }

    /// Checked once when the Recovery Status section appears — the closest practical
    /// equivalent to "at application launch" for a status surfaced only in Settings.
    func checkRecoveryStatus() async {
        status = .checking

        guard let loaded = await checkpointStore.load() else {
            checkpoint = nil
            temporaryFileExists = false
            status = .noRecoveryNeeded
            return
        }

        guard integrityValidator.isCheckpointValid(loaded) else {
            checkpoint = loaded
            temporaryFileExists = false
            status = .corrupted
            return
        }

        checkpoint = loaded
        temporaryFileExists = integrityValidator.temporaryFileExists(for: loaded)
        status = .recoveryAvailable
    }
}
