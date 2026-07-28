//
//  StorageDestination.swift
//  DualFrame
//

import Foundation

/// Where an exported recording can be sent.
/// `externalDrive` exists now so settings and future features have a stable case to
/// reference, but exporting to it is not implemented yet.
/// `nonisolated` because it's a plain value type read from multiple contexts, not the
/// default main-actor isolation this project applies to unannotated types.
nonisolated enum StorageDestination: String, CaseIterable, Identifiable, Codable {
    case internalLibrary
    case photos
    case externalDrive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .internalLibrary: "Internal Library"
        case .photos: "Photos"
        case .externalDrive: "External Drive"
        }
    }
}
