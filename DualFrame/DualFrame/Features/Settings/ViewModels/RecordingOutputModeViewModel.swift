//
//  RecordingOutputModeViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and persists `RecordingOutputModeSettings` — the user-facing "저장 방식"
/// choice. Mirrors `RecordingModeViewModel`'s pattern, with one addition: every save
/// also writes the corresponding `RecordingMode` through to
/// `RecordingModeSettingsService`, so `RecordingService`/`DualRecordingCoordinator`
/// (never modified — requirement 4) keep reading the exact same settings key they
/// always have, without needing to know `RecordingOutputMode` exists.
@MainActor
final class RecordingOutputModeViewModel: ObservableObject {
    @Published var settings: RecordingOutputModeSettings {
        didSet {
            service.save(settings)
            legacyModeService.save(RecordingModeSettings(mode: settings.outputMode.underlyingRecordingMode))
        }
    }

    private let service: RecordingOutputModeSettingsService
    private let legacyModeService: RecordingModeSettingsService

    init(
        service: RecordingOutputModeSettingsService = RecordingOutputModeSettingsService(),
        legacyModeService: RecordingModeSettingsService = RecordingModeSettingsService()
    ) {
        self.service = service
        self.legacyModeService = legacyModeService
        settings = service.load()
        // Requirement 2/backward-compat: keep the legacy key in sync on load too, not
        // just on the next change — so RecordingService's very first read after this
        // update already matches whatever output mode is actually shown/selected.
        legacyModeService.save(RecordingModeSettings(mode: settings.outputMode.underlyingRecordingMode))
    }
}
