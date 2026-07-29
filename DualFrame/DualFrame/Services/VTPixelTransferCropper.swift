//
//  VTPixelTransferCropper.swift
//  DualFrame
//

import CoreVideo
import VideoToolbox

/// Task 068: the short-form crop done by `VTPixelTransferSession` instead of CoreImage.
///
/// **Why this can be faster.** CoreImage always works in a linear RGB working space, so
/// `VideoFrameCropper` converts the YCbCr capture buffer to RGB on input and writes
/// 32BGRA on output, and the HEVC encoder then converts that BGRA back to YCbCr — two
/// conversions that cancel, around an 8.29 MB intermediate. `VTPixelTransferSession`
/// stays in YCbCr the whole way: the destination pool matches the source's own pixel
/// format, so the intermediate is 3.11 MB (0.19 GB/s vs 0.50 GB/s at 60fps) and the
/// encoder gets a buffer it can consume directly.
///
/// **The crop needs no arithmetic.** `kVTScalingMode_Trim` is defined by the SDK as
/// "the source's clean aperture scaled to a rectangle that completely fills the
/// destination, preserving the source picture aspect ratio" — which is exactly what
/// `CropCalculator.centerCropRect` computes (largest centred rect matching the target
/// aspect, then a uniform scale). So `CropStrategy.center` maps onto one property and
/// there is no rect maths to port, and therefore no chance of an off-by-one against the
/// CoreImage path. VideoToolbox has no crop-rectangle property; `Trim` is the mechanism.
///
/// **A future non-centre strategy** (Auto Reframe) would not use `Trim`. It would set
/// `kCVImageBufferCleanApertureKey` on the source buffer and switch to
/// `kVTScalingMode_CropSourceToCleanAperture`, which is why `CropCalculator` is kept
/// rather than deleted — that path still needs a rect.
///
/// Same isolation contract as `VideoFrameCropper`: `nonisolated` to opt out of the
/// project's default main-actor isolation, and called one frame at a time.
/// `RecordingService.append` awaits its whole task group before returning and the single
/// stream consumer awaits `append` per frame, so there is never a second concurrent
/// call — that, not actor isolation, is what makes the cached session and pool safe.
nonisolated final class VTPixelTransferCropper: FrameCropping {
    private var session: VTPixelTransferSession?
    private var cachedPool: CVPixelBufferPool?
    private var cachedPoolSize: CGSize?
    /// Cached alongside the size because the pool must match whatever the camera is
    /// actually delivering. Read from the source buffer rather than hardcoded, so a
    /// device that delivers 420f or a 10-bit format is handled without a code change.
    private var cachedPoolFormat: OSType?

    private(set) var lastPoolDuration: TimeInterval = 0
    private(set) var lastRenderDuration: TimeInterval = 0

    deinit {
        if let session {
            VTPixelTransferSessionInvalidate(session)
        }
    }

    func croppedPixelBuffer(from pixelBuffer: CVPixelBuffer, configuration: CropConfiguration) -> CVPixelBuffer? {
        guard configuration.targetSize.width > 0, configuration.targetSize.height > 0 else { return nil }
        guard let session = transferSession() else { return nil }

        let sourceFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let poolStart = Date()
        guard let pool = pixelBufferPool(for: configuration.targetSize, pixelFormat: sourceFormat) else { return nil }
        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
              let outputBuffer else { return nil }
        lastPoolDuration = Date().timeIntervalSince(poolStart)

        let renderStart = Date()
        // Colour fidelity: CoreImage handled colorimetry implicitly, VideoToolbox does
        // not. Without this the destination carries no YCbCr matrix / primaries /
        // transfer function, and a video-range 420v frame can be read back as full
        // range — which shows up as washed-out or crushed short-form video while the
        // long-form file looks correct. Propagating first also lets the transfer
        // override anything it does set itself.
        CVBufferPropagateAttachments(pixelBuffer, outputBuffer)

        let status = VTPixelTransferSessionTransferImage(session, from: pixelBuffer, to: outputBuffer)
        lastRenderDuration = Date().timeIntervalSince(renderStart)

        // Same contract as the CoreImage path: any failure is one skipped short-form
        // frame, never a writer failure and never anything that ends a recording.
        guard status == noErr else { return nil }
        return outputBuffer
    }

    private func transferSession() -> VTPixelTransferSession? {
        if let session { return session }

        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created) == noErr,
              let created else {
            return nil
        }

        // `Trim` is the centre-crop-and-fill mode — see the type comment.
        VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Trim)
        // This is live capture feeding a writer, not an offline transcode.
        VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)

        session = created
        return created
    }

    /// Reused across frames and rebuilt only when the target size or the source's pixel
    /// format changes — same caching rule as `VideoFrameCropper`, extended to cover the
    /// format because this pool tracks the camera's output rather than a fixed BGRA.
    private func pixelBufferPool(for size: CGSize, pixelFormat: OSType) -> CVPixelBufferPool? {
        if let cachedPool, cachedPoolSize == size, cachedPoolFormat == pixelFormat {
            return cachedPool
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]

        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        cachedPool = pool
        cachedPoolSize = size
        cachedPoolFormat = pixelFormat
        return pool
    }
}
