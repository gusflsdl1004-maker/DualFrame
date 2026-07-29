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
/// from `RecordingService`'s append path, without an extra `await` hop.
///
/// Its mutable state (the cached pool and the two timing properties) is only ever
/// touched one call at a time. Task 068 corrects the reason given here: since Task 058
/// the call no longer happens *on* the actor at all — it happens inside a
/// `withTaskGroup` child, on the cooperative pool. What actually serialises it is that
/// only the short-form profile crops, and `append` awaits its whole group before
/// returning while the single stream consumer awaits `append` per frame. So there is
/// exactly one crop in flight at any moment. If a second cropping output is ever added,
/// that guarantee disappears and this state needs real protection.
nonisolated final class VideoFrameCropper: FrameCropping {
    /// Task 056 item 2: **`cacheIntermediates: false` is the fix.**
    ///
    /// A default `CIContext` caches intermediate results, and those cache entries hold
    /// on to the `CVPixelBuffer` behind the `CIImage` they were derived from — here,
    /// the buffer the capture output just handed us. At 60fps that means a growing set
    /// of capture-pool slots retained by CoreImage rather than returned, which starves
    /// `AVCaptureVideoDataOutput`'s pool and makes it drop frames before the delegate
    /// ever runs. The cache buys nothing for this workload: every frame is different,
    /// so no intermediate is ever reused.
    ///
    /// `.priorityRequestLow: false` keeps the render at normal GPU priority — this is
    /// real-time capture, not a background export.
    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: false
    ])
    private let calculator = CropCalculator()
    private var cachedPool: CVPixelBufferPool?
    private var cachedPoolSize: CGSize?

    /// Task 061 item 2: the crop's two internal phases, timed separately so
    /// "crop time" can be split into pixel-buffer allocation versus the CoreImage
    /// render. Written on every call, read by `RecordingService` immediately after —
    /// safe because `RecordingService` is an actor and never calls this concurrently
    /// with itself (the same reasoning that already permits `cachedPool`).
    /// Measurement only: no call site behaviour changes.
    /// Recorded in every configuration now, not just Debug: the Long-only vs
    /// Long+Short difference is a Release symptom, so the cost that explains it has to
    /// be measurable in Release.
    private(set) var lastPoolDuration: TimeInterval = 0
    private(set) var lastRenderDuration: TimeInterval = 0

    /// Returns a new pixel buffer at `configuration.targetSize`, containing the
    /// center-cropped-and-scaled contents of `pixelBuffer` — never stretched, since the
    /// crop rect `CropCalculator` returns already matches `targetSize`'s aspect ratio.
    /// Returns `nil` on any failure (degenerate crop rect, pool allocation failure,
    /// render failure); the caller treats that like a single dropped frame rather than
    /// a writer failure — one bad frame must never end the whole recording.
    func croppedPixelBuffer(from pixelBuffer: CVPixelBuffer, configuration: CropConfiguration) -> CVPixelBuffer? {
        // Task 056 item 2: the `CIImage` chain below retains the source pixel buffer,
        // and its intermediates are autoreleased. This runs inside a `Task`, not a
        // dispatch work item, so there is no enclosing pool draining per frame — an
        // explicit one returns the capture buffer on this frame instead of whenever the
        // task next happens to suspend.
        autoreleasepool {
            cropped(from: pixelBuffer, configuration: configuration)
        }
    }

    private func cropped(from pixelBuffer: CVPixelBuffer, configuration: CropConfiguration) -> CVPixelBuffer? {
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

        let poolStart = Date()
        guard let pool = pixelBufferPool(for: configuration.targetSize) else { return nil }

        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
              let outputBuffer else { return nil }
        lastPoolDuration = Date().timeIntervalSince(poolStart)
        let renderStart = Date()

        context.render(croppedImage, to: outputBuffer)
        lastRenderDuration = Date().timeIntervalSince(renderStart)
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
