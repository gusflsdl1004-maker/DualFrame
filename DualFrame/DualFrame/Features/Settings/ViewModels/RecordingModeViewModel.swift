//
//  RecordingModeViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and persists `RecordingModeSettings`. Mirrors `RecordingQualityViewModel`.
/// Owns no persistence itself — that lives in `RecordingModeSettingsService`.
@MainActor
final class RecordingModeViewModel: ObservableObject {
    @Published var settings: RecordingModeSettings {
        didSet { service.save(settings) }
    }

    private let service: RecordingModeSettingsService

    init(service: RecordingModeSettingsService = RecordingModeSettingsService()) {
        self.service = service
        settings = service.load()
    }
}
