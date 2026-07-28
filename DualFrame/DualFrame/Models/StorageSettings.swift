//
//  StorageSettings.swift
//  DualFrame
//

import Foundation

/// The user's persisted preferences for where exports go.
/// `nonisolated` for the same reason as `StorageDestination`.
nonisolated struct StorageSettings: Codable, Equatable {
    var defaultDestination: StorageDestination
    var askEveryTime: Bool
    var keepInternalCopy: Bool

    /// Safe defaults: ask before exporting, and never remove the internal copy —
    /// consistent with CLAUDE.md's "never lose recorded video" principle.
    static let `default` = StorageSettings(
        defaultDestination: .internalLibrary,
        askEveryTime: true,
        keepInternalCopy: true
    )
}
