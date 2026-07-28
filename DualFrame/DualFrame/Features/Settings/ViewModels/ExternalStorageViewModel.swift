//
//  ExternalStorageViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Tracks the currently selected external storage location for display, for gating
/// the "External Drive" option in Storage Settings, and for other view models
/// (e.g. the video library) that need the destination URL to export to.
/// Owns no file I/O itself — that lives in `ExternalStorageService`.
///
/// The selected URL is only kept in memory for this session — no bookmark is
/// persisted, so the connection is lost on relaunch (see Task 010/011 limitations).
@MainActor
final class ExternalStorageViewModel: ObservableObject {
    @Published private(set) var device: ExternalStorageDevice?
    @Published private(set) var status: ExternalStorageStatus = .disconnected
    @Published private(set) var errorMessage: String?

    /// The raw picked URL, kept so a later export can re-open a security-scoped
    /// access window on it. Not `@Published` — it isn't displayed directly.
    private(set) var selectedURL: URL?

    private let service: ExternalStorageService

    init(service: ExternalStorageService = ExternalStorageService()) {
        self.service = service
    }

    /// Reads metadata for a location the user just picked through the Files picker.
    func connect(to url: URL) {
        do {
            device = try service.makeDevice(from: url)
            selectedURL = url
            status = .connected
            errorMessage = nil
        } catch {
            device = nil
            selectedURL = nil
            status = .unavailable
            errorMessage = "Could not read the selected storage location."
        }
    }

    func disconnect() {
        device = nil
        selectedURL = nil
        status = .disconnected
        errorMessage = nil
    }
}
