//
//  DiagnosticsViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads saved `RecordingDiagnostics` sessions for display, newest first.
/// Owns no file I/O itself — that lives in `RecordingDiagnosticsService`. Read-only:
/// nothing here edits or deletes a diagnostics record.
@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published private(set) var sessions: [RecordingDiagnostics] = []

    private let service: RecordingDiagnosticsService

    init(service: RecordingDiagnosticsService = RecordingDiagnosticsService()) {
        self.service = service
    }

    func refresh() async {
        let loaded = await service.loadAll()
        sessions = loaded.sorted { $0.recordingStartTime > $1.recordingStartTime }
    }
}
