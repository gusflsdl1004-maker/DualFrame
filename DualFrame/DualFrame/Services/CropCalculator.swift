//
//  CropCalculator.swift
//  DualFrame
//

import CoreGraphics

/// Computes where to crop a source frame for a given `CropConfiguration`. A pure
/// function with no AVFoundation/CoreImage dependency — kept separate from
/// `VideoFrameCropper` (which does the actual pixel work) specifically so a future
/// Auto Reframe strategy only has to change this type (requirement 3/6).
nonisolated struct CropCalculator {
    /// The rect, in `sourceSize`'s coordinate space, that should be cropped and then
    /// scaled up to fill `configuration.targetSize` with no distortion.
    func cropRect(sourceSize: CGSize, configuration: CropConfiguration) -> CGRect {
        switch configuration.strategy {
        case .center:
            Self.centerCropRect(sourceSize: sourceSize, targetSize: configuration.targetSize)
        }
    }

    /// The largest rect centered in `sourceSize` whose aspect ratio exactly matches
    /// `targetSize`'s. Scaling this rect up to `targetSize` afterward is always a
    /// uniform scale (both dimensions by the same factor) — never a stretch.
    private static func centerCropRect(sourceSize: CGSize, targetSize: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, targetSize.width > 0, targetSize.height > 0 else {
            return CGRect(origin: .zero, size: sourceSize)
        }

        let sourceAspect = sourceSize.width / sourceSize.height
        let targetAspect = targetSize.width / targetSize.height

        let cropSize: CGSize
        if sourceAspect > targetAspect {
            // Source is wider than the target (e.g. 16:9 source, 9:16 target) — crop
            // the left/right edges, keep the full height.
            cropSize = CGSize(width: sourceSize.height * targetAspect, height: sourceSize.height)
        } else {
            // Source is narrower/taller than the target — crop top/bottom, keep the
            // full width.
            cropSize = CGSize(width: sourceSize.width, height: sourceSize.width / targetAspect)
        }

        let origin = CGPoint(
            x: (sourceSize.width - cropSize.width) / 2,
            y: (sourceSize.height - cropSize.height) / 2
        )
        return CGRect(origin: origin, size: cropSize)
    }
}
