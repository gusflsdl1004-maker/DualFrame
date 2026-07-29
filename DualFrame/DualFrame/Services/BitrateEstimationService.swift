//
//  BitrateEstimationService.swift
//  DualFrame
//

import Foundation

/// The video bitrate one writer is configured with, per resolution and frame rate.
///
/// Task 049: this is no longer an *estimate*. `RecordingService.makeWriterContext` now
/// sets `AVVideoAverageBitRateKey` from exactly these values, so this type is the
/// single definition of the recording bitrate — used both to configure the encoder and
/// to compute "예상 촬영 가능" in `RecordingCapacityViewModel`. Previously the writer
/// set no bitrate at all and let AVFoundation pick one internally, which caused two
/// separate problems: 4K was encoded at whatever default the encoder chose (the
/// reported quality loss), and the remaining-time estimate was derived from a number
/// nothing actually used.
///
/// Bitrate is `pixels × fps × bitsPerPixel`, with `bitsPerPixel` tiered by resolution —
/// higher resolutions tolerate a lower ratio because neighbouring pixels are more
/// redundant. The tiers land on these H.264 targets, which sit in the range YouTube
/// recommends for upload and Apple's own Camera app produces:
///
///     HD   (1280×720)   30fps ≈   8 Mbps    60fps ≈  16 Mbps
///     FHD  (1920×1080)  30fps ≈  16 Mbps    60fps ≈  32 Mbps
///     4K   (3840×2160)  30fps ≈  50 Mbps    60fps ≈ 100 Mbps
///
/// Short-form (1080×1920) has the same pixel count as FHD and so lands in the same
/// tier, which is correct — it is a full-quality vertical output, not a thumbnail.
nonisolated struct BitrateEstimationService {
    /// Mirrors `RecordingService.makeWriterContext`'s literal `AVEncoderBitRateKey`
    /// value for the audio track (64 kbps AAC mono).
    private let audioBitrateBps: Double
    /// Task 050 requirement 3: read fresh on construction so a preset change applies to
    /// the next recording and to the next capacity refresh alike.
    private let presetService: BitratePresetSettingsService

    init(
        audioBitrateBps: Double = 64_000,
        presetService: BitratePresetSettingsService = BitratePresetSettingsService()
    ) {
        self.audioBitrateBps = audioBitrateBps
        self.presetService = presetService
    }

    /// The preset currently in effect.
    var currentPreset: BitratePreset {
        presetService.load().preset
    }

    /// Bits per pixel per frame for a given frame size. Tiered rather than constant —
    /// a single ratio cannot serve 720p and 4K well at the same time.
    private func bitsPerPixel(width: Int, height: Int) -> Double {
        switch width * height {
        case ...(1280 * 720): 0.29
        case ...(1920 * 1080): 0.26
        default: 0.20
        }
    }

    /// The video bitrate a writer at `width`×`height` and `fps` is configured with,
    /// scaled by the user's quality preset (Task 050 requirement 3).
    func videoBitrateBps(width: Int, height: Int, fps: RecordingFPS) -> Double {
        let base = Double(width * height) * Double(fps.rawValue) * bitsPerPixel(width: width, height: height)
        return base * currentPreset.bitrateMultiplier
    }

    /// Integer form, for `AVVideoAverageBitRateKey`.
    func videoBitrate(width: Int, height: Int, fps: RecordingFPS) -> Int {
        Int(videoBitrateBps(width: width, height: height, fps: fps))
    }

    /// Retained name from Task 041 so existing call sites keep working; now returns the
    /// configured bitrate rather than an approximation of an unknown one.
    func estimatedVideoBitrateBps(width: Int, height: Int, fps: RecordingFPS) -> Double {
        videoBitrateBps(width: width, height: height, fps: fps)
    }

    /// Video + one audio track, for a single writer.
    func estimatedWriterBitrateBps(width: Int, height: Int, fps: RecordingFPS) -> Double {
        videoBitrateBps(width: width, height: height, fps: fps) + audioBitrateBps
    }
}
