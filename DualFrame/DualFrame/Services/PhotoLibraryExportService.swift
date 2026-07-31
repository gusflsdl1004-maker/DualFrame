//
//  PhotoLibraryExportService.swift
//  DualFrame
//

import Photos

/// Errors from exporting a video to the Photos app.
nonisolated enum PhotoLibraryExportError: Error {
    case permissionDenied
    case exportFailed
}

/// The outcome of exporting a single recording, keyed per-recording in the library view.
nonisolated enum PhotoLibraryExportStatus: Equatable {
    case idle
    case exporting
    case success
    case failed(permissionDenied: Bool)
}

/// Copies a recording from the internal library into the user's Photos library.
/// Uses the "add only" access level — this app never reads or modifies the user's
/// existing photos, it only adds new ones. The source file is never touched or deleted.
nonisolated struct PhotoLibraryExportService {
    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let current = authorizationStatus()
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    /// Task 091: copies the still at `fileURL` into Photos. Same contract as
    /// `exportVideo(at:)` — the app's own copy is left untouched, so a failure here
    /// never costs the user the capture.
    ///
    /// `addResource(with:fileURL:options:)` rather than
    /// `creationRequestForAssetFromImage(atFileURL:)`: it hands Photos the original file
    /// bytes, so the HEIC/JPEG and its EXIF land intact rather than being re-encoded.
    func exportPhoto(at fileURL: URL) async throws {
        let status = await requestAuthorizationIfNeeded()
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryExportError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: fileURL, options: options)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoLibraryExportError.exportFailed)
                }
            }
        }
    }

    /// Copies the video at `fileURL` into Photos. The original file at `fileURL` is
    /// left untouched — `PHAssetChangeRequest` only reads from it to create a copy.
    func exportVideo(at fileURL: URL) async throws {
        let status = await requestAuthorizationIfNeeded()
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryExportError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoLibraryExportError.exportFailed)
                }
            }
        }
    }
}
