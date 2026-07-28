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
