//
//  DeviceCapabilityService.swift
//  DualFrame
//

import AVFoundation

/// Task 039 requirement 5: lets the Settings screens (`RecordingQualityView`/
/// `RecordingFPSView`) know which resolutions/frame rates the currently-selected
/// camera actually supports, so unsupported options can be disabled instead of only
/// being caught later when a recording starts. Queries a fresh `AVCaptureDevice`
/// reference directly — reading `.formats` doesn't require exclusive access, so this
/// works safely even while `CameraService`'s session is already running.
///
/// Deliberately independent of `CameraService` — it has no reason to depend on a live
/// capture session, only on the device's static format list, so Settings can query
/// this without needing a `CameraService` instance at all.
nonisolated struct DeviceCapabilityService {
    private let positionSettingsService: CameraPositionSettingsService

    init(positionSettingsService: CameraPositionSettingsService = CameraPositionSettingsService()) {
        self.positionSettingsService = positionSettingsService
    }

    private var currentDevice: AVCaptureDevice? {
        let position = positionSettingsService.load().selectedPosition
        let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition)
    }

    /// Whether the currently-selected camera has any format at `quality`'s pixel
    /// dimensions. If the device can't be looked up (e.g. no camera at all), returns
    /// `true` rather than disabling every option — `CameraService` will still resolve
    /// and report a fallback at actual configuration time either way.
    func isSupported(_ quality: RecordingQuality) -> Bool {
        guard let device = currentDevice else { return true }
        return !matchingFormats(on: device, dimensions: quality.dimensions).isEmpty
    }

    /// Whether the currently-selected camera has a format at `quality`'s dimensions
    /// that also supports `fps`.
    func isSupported(_ fps: RecordingFPS, at quality: RecordingQuality) -> Bool {
        guard let device = currentDevice else { return true }
        let requestedRate = Double(fps.rawValue)
        return matchingFormats(on: device, dimensions: quality.dimensions).contains { format in
            format.videoSupportedFrameRateRanges.contains { requestedRate >= $0.minFrameRate && requestedRate <= $0.maxFrameRate }
        }
    }

    private func matchingFormats(on device: AVCaptureDevice, dimensions target: (width: Int, height: Int)) -> [AVCaptureDevice.Format] {
        device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dimensions.width) == target.width && Int(dimensions.height) == target.height
        }
    }
}
