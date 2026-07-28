//
//  ExternalStorageViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Tracks the currently selected external storage location for display and for
/// gating the "External Drive" option in Storage Settings.
/// Owns no file I/O itself — that lives in `ExternalStorageService`.
@MainActor
final class ExternalStorageViewModel: ObservableObject {
    @Published private(set) var device: ExternalStorageDevice?
    @Published private(set) var status: ExternalStorageStatus = .disconnected
    @Published private(set) var errorMessage: String?

    private let service: ExternalStorageService

    init(service: ExternalStorageService = ExternalStorageService()) {
        self.service = service
    }

    /// Reads metadata for a location the user just picked through the Files picker.
    func connect(to url: URL) {
        do {
            device = try service.makeDevice(from: url)
            status = .connected
            errorMessage = nil
        } catch {
            device = nil
            status = .unavailable
            errorMessage = "Could not read the selected storage location."
        }
    }

    func disconnect() {
        device = nil
        status = .disconnected
        errorMessage = nil
    }
}
