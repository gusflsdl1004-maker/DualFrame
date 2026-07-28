//
//  StorageSettingsViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Loads and persists `StorageSettings` for the storage destination screen.
/// Owns no persistence itself — that lives in `StorageSettingsService`.
@MainActor
final class StorageSettingsViewModel: ObservableObject {
    @Published var settings: StorageSettings {
        didSet { service.save(settings) }
    }

    private let service: StorageSettingsService

    init(service: StorageSettingsService = StorageSettingsService()) {
        self.service = service
        settings = service.load()
    }
}
