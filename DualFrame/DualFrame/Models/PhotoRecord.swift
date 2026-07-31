//
//  PhotoRecord.swift
//  DualFrame
//

import CoreGraphics
import Foundation

/// A single still image stored in the app's internal library.
///
/// Task 091: **a new type rather than a field on `VideoRecord`.** CLAUDE.md rule 58 —
/// existing data is never migrated, and a recording already on disk must never become
/// invisible or malformed because a new feature arrived. Adding a `kind` to `VideoRecord`
/// would have meant every existing record decoding through a changed shape; a separate
/// type means the video library is bit-for-bit unaffected by photos existing.
///
/// The two are brought together only at the presentation layer (`LibraryItem`), which is
/// the reference layer rule 58 asks for.
nonisolated struct PhotoRecord: Identifiable, Equatable {
    let id: String
    let filename: String
    let createdAt: Date
    /// Pixel dimensions of the stored image.
    let resolution: CGSize
    let fileSize: Int64
    let localURL: URL
    /// Which camera took it. Recorded because it is the one piece of capture context that
    /// cannot be recovered from the file afterwards on every device.
    let cameraPosition: CameraPosition?
}

/// Whether the shutter records video or takes a still.
///
/// Deliberately not persisted: the app opens in video mode every launch. This is a camera
/// that records long-form video and derives shorts from it — photos are the secondary
/// mode, and a user who took one photo yesterday should not find the shutter pointed
/// somewhere unexpected today.
nonisolated enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case video
    case photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "VIDEO"
        case .photo: "PHOTO"
        }
    }

    var symbolName: String {
        switch self {
        case .video: "video.fill"
        case .photo: "camera.fill"
        }
    }

    var toggled: CaptureMode { self == .video ? .photo : .video }
}
