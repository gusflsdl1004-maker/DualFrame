//
//  RecordingFPSViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and persists `RecordingFPSSettings`.
/// Owns no persistence itself — that lives in `RecordingFPSSettingsService`.
@MainActor
final class RecordingFPSViewModel: ObservableObject {
    @Published var settings: RecordingFPSSettings {
        didSet { service.save(settings) }
    }

    private let service: RecordingFPSSettingsService

    init(service: RecordingFPSSettingsService = RecordingFPSSettingsService()) {
        self.service = service
        settings = service.load()
    }
}
