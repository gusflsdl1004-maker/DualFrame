//
//  BitratePresetViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and persists `BitratePresetSettings`. Mirrors `RecordingQualityViewModel`.
@MainActor
final class BitratePresetViewModel: ObservableObject {
    @Published var settings: BitratePresetSettings {
        didSet { service.save(settings) }
    }

    private let service: BitratePresetSettingsService

    init(service: BitratePresetSettingsService = BitratePresetSettingsService()) {
        self.service = service
        settings = service.load()
    }
}
