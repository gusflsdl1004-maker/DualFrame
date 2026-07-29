//
//  BitrateEstimationService.swift
//  DualFrame
//

import Foundation

/// Task 041: estimates the H.264 encoder bitrate `RecordingService`'s `AVAssetWriter`
/// would use for a given resolution/FPS.
///
/// `RecordingService.makeWriterContext` sets only `AVVideoCodecKey`/`AVVideoWidthKey`/
/// `AVVideoHeightKey` on its video settings — no explicit `AVVideoAverageBitRateKey` —
/// so AVFoundation picks a bitrate internally that this app has no API to read back
/// before a recording starts. This is a deliberate **estimate** using the standard
/// "bits per pixel" video-industry approximation
/// (`bitrate = width × height × fps × bitsPerPixel`), not a literal reading of what
/// AVFoundation will actually use. See the Task 041 report's Known Issues for how to
/// calibrate `bitsPerPixel` against a real recording's actual file size.
nonisolated struct BitrateEstimationService {
    /// A moderate "reasonably good quality" H.264 compression estimate. Real-world
    /// consumer H.264 video typically falls in the 0.1–0.2 bits-per-pixel range;
    /// 0.15 is the midpoint.
    private let bitsPerPixel: Double

    /// Mirrors `RecordingService.makeWriterContext`'s literal `AVEncoderBitRateKey`
    /// value for the audio track (64 kbps AAC mono) — duplicated here since that
    /// constant lives inside the forbidden `RecordingService.swift`. If it's ever
    /// changed there, this should be updated to match.
    private let audioBitrateBps: Double

    init(bitsPerPixel: Double = 0.15, audioBitrateBps: Double = 64_000) {
        self.bitsPerPixel = bitsPerPixel
        self.audioBitrateBps = audioBitrateBps
    }

    /// Requirement 2: estimated video-only bitrate for one writer at `width`×`height`
    /// pixels and `fps`.
    func estimatedVideoBitrateBps(width: Int, height: Int, fps: RecordingFPS) -> Double {
        Double(width) * Double(height) * Double(fps.rawValue) * bitsPerPixel
    }

    /// Video + one audio track's estimated bitrate for a single writer.
    func estimatedWriterBitrateBps(width: Int, height: Int, fps: RecordingFPS) -> Double {
        estimatedVideoBitrateBps(width: width, height: height, fps: fps) + audioBitrateBps
    }
}
