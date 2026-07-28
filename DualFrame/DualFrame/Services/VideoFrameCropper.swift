//
//  VideoFrameCropper.swift
//  DualFrame
//

import CoreImage
import CoreVideo

/// Crops and scales one captured video frame per a `CropConfiguration`, using
/// CoreImage. `RecordingService` only calls this for the short-form output's video —
/// long-form and `.single` mode never pass through here (see `RecordingService.append`),
/// so their frames stay the exact same untouched sample buffers they always were
/// (requirement: Long Recording 영향 없음, Single Recording 영향 없음).
///
/// `nonisolated` to opt out of this project's default main-actor isolation
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) — this must be callable synchronously
/// from `RecordingService`'s actor-isolated `append`, without an extra `await` hop. Its
/// mutable state (the cached pixel buffer pool) is only ever touched from that single
/// call site, one call at a time, since `RecordingService` is an actor and never calls
/// this concurrently with itself.
nonisolated final class VideoFrameCropper {
    private let context = CIContext()
    private let calculator = CropCalculator()
    private var cachedPool: CVPixelBufferPool?
    private var cachedPoolSize: CGSize?

    /// Returns a new pixel buffer at `configuration.targetSize`, containing the
    /// center-cropped-and-scaled contents of `pixelBuffer` — never stretched, since the
    /// crop rect `CropCalculator` returns already matches `targetSize`'s aspect ratio.
    /// Returns `nil` on any failure (degenerate crop rect, pool allocation failure,
    /// render failure); the caller treats that like a single dropped frame rather than
    /// a writer failure — one bad frame must never end the whole recording.
    func croppedPixelBuffer(from pixelBuffer: CVPixelBuffer, configuration: CropConfiguration) -> CVPixelBuffer? {
        let sourceSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let cropRect = calculator.cropRect(sourceSize: sourceSize, configuration: configuration)
        guard cropRect.width > 0, cropRect.height > 0 else { return nil }

        let scale = configuration.targetSize.width / cropRect.width
        let croppedImage = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let pool = pixelBufferPool(for: configuration.targetSize) else { return nil }

        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
              let outputBuffer else { return nil }

        context.render(croppedImage, to: outputBuffer)
        return outputBuffer
    }

    /// Reuses the pool across frames (allocating a fresh `CVPixelBufferPool` per frame
    /// would be wasteful) — only rebuilt if the target size changes.
    private func pixelBufferPool(for size: CGSize) -> CVPixelBufferPool? {
        if let cachedPool, cachedPoolSize == size {
            return cachedPool
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]

        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        cachedPool = pool
        cachedPoolSize = size
        return pool
    }
}
