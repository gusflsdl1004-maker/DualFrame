//
//  InternalPhotoLibraryService.swift
//  DualFrame
//

import CoreGraphics
import Foundation
import ImageIO

nonisolated enum InternalPhotoLibraryError: Error {
    case directoryUnavailable
    case writeFailed
    case recordNotFound
}

/// The app's internal photo library: writes captured stills into Application Support and
/// lists them back.
///
/// Task 091: a sibling of `InternalVideoLibraryService`, not a change to it. The video
/// library's directory, filenames and metadata are untouched, so nothing about photos
/// existing can affect a recording already on disk (CLAUDE.md rule 58).
///
/// Stills need no metadata sidecar. Everything a `PhotoRecord` carries — dimensions,
/// size, creation date — is either a file attribute or readable from the image header via
/// `CGImageSource`, so the file on disk is the single source of truth and there is no
/// second store that can disagree with it. That is deliberately unlike the video library,
/// which needs a sidecar for session identity.
actor InternalPhotoLibraryService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Writes `data` (a complete HEIC/JPEG file from `AVCapturePhotoOutput`, EXIF
    /// included) and returns the record for it.
    ///
    /// Written to a temporary name first and then moved into place. A crash or a full
    /// disk mid-write therefore leaves a partial file that no listing will ever show,
    /// rather than a half-written image sitting in the library looking valid — the same
    /// reasoning the recording path uses for its temporary files (CLAUDE.md rule 29).
    func save(
        data: Data,
        capturedAt: Date,
        cameraPosition: CameraPosition?,
        fileExtension: String,
        quality: PhotoQuality
    ) throws -> PhotoRecord {
        let directory = try photosDirectory()
        let filename = uniqueFilename(for: capturedAt, in: directory, fileExtension: fileExtension)
        let finalURL = directory.appendingPathComponent(filename)
        let stagingURL = directory.appendingPathComponent(".\(filename).partial")

        do {
            try data.write(to: stagingURL, options: .atomic)
            try fileManager.moveItem(at: stagingURL, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw InternalPhotoLibraryError.writeFailed
        }

        // Task 094: written after the image is safely in place, and best-effort — a
        // sidecar that fails to write costs a debug row, never the photo.
        writeMetadata(
            PhotoCaptureMetadata(quality: quality, cameraPosition: cameraPosition, savedToPhotos: false),
            for: finalURL
        )

        return makeRecord(from: finalURL)
            ?? PhotoRecord(
                id: filename,
                filename: filename,
                createdAt: capturedAt,
                resolution: .zero,
                fileSize: Int64(data.count),
                localURL: finalURL,
                cameraPosition: cameraPosition,
                captureQuality: quality,
                savedToPhotos: false,
                exifResolution: nil
            )
    }

    /// Task 094: records that a copy reached Photos. Called after a successful export so
    /// the debug panel can state where this photo actually lives.
    func markSavedToPhotos(_ record: PhotoRecord) {
        guard var metadata = readMetadata(for: record.localURL) else { return }
        metadata.savedToPhotos = true
        writeMetadata(metadata, for: record.localURL)
    }

    /// Newest first, matching the gallery's ordering.
    func loadAllRecords() throws -> [PhotoRecord] {
        let directory = try photosDirectory()
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { makeRecord(from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ record: PhotoRecord) throws {
        guard fileManager.fileExists(atPath: record.localURL.path) else {
            throw InternalPhotoLibraryError.recordNotFound
        }
        try fileManager.removeItem(at: record.localURL)
        // The sidecar goes with the image. Leaving it would accumulate orphans that
        // nothing ever lists and nothing ever cleans up.
        try? fileManager.removeItem(at: metadataURL(for: record.localURL))
    }

    // MARK: - Capture metadata sidecar (Task 094)

    private func metadataURL(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension("meta.json")
    }

    private func writeMetadata(_ metadata: PhotoCaptureMetadata, for imageURL: URL) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL(for: imageURL), options: .atomic)
    }

    private func readMetadata(for imageURL: URL) -> PhotoCaptureMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(for: imageURL)) else { return nil }
        return try? JSONDecoder().decode(PhotoCaptureMetadata.self, from: data)
    }

    // MARK: - Private

    private static let supportedExtensions: Set<String> = ["heic", "jpg", "jpeg"]

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func photosDirectory() throws -> URL {
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw InternalPhotoLibraryError.directoryUnavailable
        }

        // A sibling of Videos/, never inside it — so the video library's listing, which
        // enumerates its own directory, cannot see photos even transiently.
        let directory = appSupport
            .appendingPathComponent("DualFrame", isDirectory: true)
            .appendingPathComponent("Photos", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func uniqueFilename(for date: Date, in directory: URL, fileExtension: String) -> String {
        let base = Self.filenameFormatter.string(from: date)
        var candidate = "\(base).\(fileExtension)"
        var suffix = 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)_\(suffix).\(fileExtension)"
            suffix += 1
        }
        return candidate
    }

    /// Dimensions come from the image header via `CGImageSource`, which reads only the
    /// metadata block rather than decoding the pixels — listing a library of 4000 photos
    /// must not decode 4000 images.
    private func makeRecord(from url: URL) -> PhotoRecord? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let fileSize = attributes[.size] as? Int64 ?? 0
        let createdAt = attributes[.creationDate] as? Date ?? Date()

        var resolution = CGSize.zero
        var exifResolution: CGSize?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            resolution = CGSize(width: width, height: height)

            // Task 094: EXIF carries its own dimensions, and they can disagree with the
            // container's — that disagreement is exactly the kind of thing this panel
            // exists to surface, so both are reported rather than one being trusted.
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                let exifWidth = (exif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.doubleValue ?? 0
                let exifHeight = (exif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.doubleValue ?? 0
                if exifWidth > 0, exifHeight > 0 {
                    exifResolution = CGSize(width: exifWidth, height: exifHeight)
                }
            }
        }

        let metadata = readMetadata(for: url)
        return PhotoRecord(
            id: url.lastPathComponent,
            filename: url.lastPathComponent,
            createdAt: createdAt,
            resolution: resolution,
            fileSize: fileSize,
            localURL: url,
            cameraPosition: metadata?.cameraPosition,
            captureQuality: metadata?.quality,
            savedToPhotos: metadata?.savedToPhotos,
            exifResolution: exifResolution
        )
    }
}
