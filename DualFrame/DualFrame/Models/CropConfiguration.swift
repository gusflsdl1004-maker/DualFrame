//
//  CropConfiguration.swift
//  DualFrame
//

import CoreGraphics

/// How a frame should be cropped before being written to a specific output profile.
///
/// Extension point (Task 021 requirement 6 — future Auto Reframe): a face-tracking
/// crop strategy would add a new case here (e.g. `.faceTracking`) plus a matching
/// branch in `CropCalculator.cropRect(sourceSize:configuration:)`. Nothing else in the
/// pipeline needs to change — `VideoFrameCropper` only ever consumes the `CGRect`
/// `CropCalculator` returns, never the strategy itself.
nonisolated enum CropStrategy: Equatable {
    case center
}

/// Pairs a crop strategy with the output size it must fill. `targetSize` is always the
/// destination `OutputProfile`'s resolution, so the cropped-and-scaled result exactly
/// matches what the writer expects — the writer's configured dimensions are never
/// violated by cropping.
nonisolated struct CropConfiguration: Equatable {
    let targetSize: CGSize
    let strategy: CropStrategy
}
