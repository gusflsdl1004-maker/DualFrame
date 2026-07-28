//
//  RecordingQualityViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and persists `RecordingQualitySettings`.
/// Owns no persistence itself — that lives in `RecordingQualitySettingsService`.
@MainActor
final class RecordingQualityViewModel: ObservableObject {
    @Published var settings: RecordingQualitySettings {
        didSet { service.save(settings) }
    }

    private let service: RecordingQualitySettingsService

    init(service: RecordingQualitySettingsService = RecordingQualitySettingsService()) {
        self.service = service
        settings = service.load()
    }
}
