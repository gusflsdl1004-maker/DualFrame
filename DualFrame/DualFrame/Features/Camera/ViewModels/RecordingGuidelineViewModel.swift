//
//  RecordingGuidelineViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and persists `RecordingGuidelineSettings`. Mirrors `RecordingModeViewModel`.
/// Owns no persistence itself — that lives in `RecordingGuidelineSettingsService`.
@MainActor
final class RecordingGuidelineViewModel: ObservableObject {
    @Published var settings: RecordingGuidelineSettings {
        didSet { service.save(settings) }
    }

    private let service: RecordingGuidelineSettingsService

    init(service: RecordingGuidelineSettingsService = RecordingGuidelineSettingsService()) {
        self.service = service
        settings = service.load()
    }
}
