//
//  ExternalStorageDevice.swift
//  DualFrame
//

import Foundation

/// A storage location outside the app sandbox that the user picked through the
/// Files app (e.g. a USB drive or SD card). `nonisolated` for the same reason as
/// the other model types in this project.
nonisolated struct ExternalStorageDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let isAvailable: Bool
    let availableSpace: Int64
    let totalSpace: Int64
}
