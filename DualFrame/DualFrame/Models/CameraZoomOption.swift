//
//  CameraZoomOption.swift
//  DualFrame
//

import Foundation

/// One quick-select zoom button (Task 043 requirement 3/5) — e.g. "0.5" for the
/// ultra-wide lens, "1" for the wide lens, "3" for the telephoto lens. `factor` is the
/// exact `AVCaptureDevice.videoZoomFactor` value that lens corresponds to; `label` is
/// what's shown on the button. Kept free of AVFoundation (matches `RecordingQuality`'s
/// pattern) — `CameraService` is the only place that knows how these are derived from
/// the device's actual lenses.
nonisolated struct CameraZoomOption: Identifiable, Equatable {
    let id: String
    let factor: CGFloat
    let label: String
}
