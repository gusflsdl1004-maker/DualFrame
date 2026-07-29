//
//  FrameCropping.swift
//  DualFrame
//

import CoreVideo
import Foundation

/// What `RecordingService.performAppend` needs from a cropper, so the CoreImage and
/// VideoToolbox implementations are interchangeable without the append path knowing
/// which one it has.
///
/// Task 068: introduced so the existing implementation could stay **byte-for-byte
/// unchanged** while a second one is added beside it. `performAppend`'s body does not
/// change at all — it still calls `croppedPixelBuffer(from:configuration:)`, still
/// treats `nil` as one skipped short-form frame, and still reads the same two timing
/// properties afterwards.
///
/// Deliberately not constrained to `Sendable`: this project builds in Swift 5 language
/// mode and `VideoFrameCropper` is already captured by the append task group exactly as
/// written. Adding a conformance requirement here would change the concurrency
/// contract of code this task is supposed to leave alone.
nonisolated protocol FrameCropping: AnyObject {
    /// Returns a new buffer at `configuration.targetSize` containing the cropped and
    /// scaled source, or `nil` on any failure. `nil` must always mean "skip this one
    /// short-form frame" — never a writer failure, and never anything that could end a
    /// recording (CLAUDE.md rule 1).
    func croppedPixelBuffer(from pixelBuffer: CVPixelBuffer, configuration: CropConfiguration) -> CVPixelBuffer?

    /// Time spent obtaining the destination buffer on the last call.
    var lastPoolDuration: TimeInterval { get }
    /// Time spent doing the actual crop/scale on the last call.
    var lastRenderDuration: TimeInterval { get }
}
