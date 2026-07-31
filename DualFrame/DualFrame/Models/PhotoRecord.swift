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
    /// Task 094: what was *asked for* at capture time, as opposed to what the file turned
    /// out to be. `nil` for anything captured before Task 094 — see `PhotoCaptureMetadata`.
    let captureQuality: PhotoQuality?
    /// Whether a copy was also written to Photos. `nil` when unrecorded.
    let savedToPhotos: Bool?
    /// Task 094: the resolution EXIF claims, which is not always the container's.
    let exifResolution: CGSize?
}

/// Task 094: the handful of capture-time facts a photo file cannot answer for itself.
///
/// **Why a sidecar at all**, when Task 091 deliberately gave photos none: the debug panel
/// has to show *requested* quality next to *actual* result, and "requested" exists only in
/// the app. A file that came out JPEG cannot say whether that was 표준 asking for JPEG or
/// 고화질 falling back — and telling those apart is the entire point of the panel.
///
/// Written next to the image and deleted with it. Absent for every photo captured before
/// this task, and absence is handled everywhere rather than migrated (CLAUDE.md rule 58):
/// an older photo simply reports 기록 없음 and everything else about it still works.
nonisolated struct PhotoCaptureMetadata: Codable, Equatable, Sendable {
    var quality: PhotoQuality
    var cameraPosition: CameraPosition?
    var savedToPhotos: Bool
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
