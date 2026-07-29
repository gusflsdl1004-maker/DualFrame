//
//  DeviceCapabilityService.swift
//  DualFrame
//

import AVFoundation

/// Task 039 requirement 5: lets the Settings screens (`RecordingQualityView`/
/// `RecordingFPSView`) know which resolutions/frame rates the camera actually
/// supports, so unsupported options can be disabled instead of only being caught later
/// when a recording starts. Queries a fresh `AVCaptureDevice` reference directly —
/// reading `.formats` doesn't require exclusive access, so this works safely even
/// while `CameraService`'s session is already running.
///
/// Task 049: this is now also the **single source of truth for which camera to bind**,
/// used by `CameraService` itself.
///
/// The 4K60 bug it fixes: this type used to answer "is 4K60 supported?" by looking at
/// `.builtInWideAngleCamera` alone, while `CameraService` bound whichever *virtual*
/// multi-lens device its own separate search picked. Two independent implementations
/// answering the same question over different device sets — so Settings and the
/// capture path could disagree about the very same combination, and the user saw an
/// option either wrongly blocked or wrongly offered and then silently downgraded.
/// Both now go through the same `bestDevice`/`supports` pair, so the answer Settings
/// gives is by construction the answer capture will act on.
nonisolated struct DeviceCapabilityService {
    /// Richest first, single-lens last. A virtual multi-lens device is preferred so
    /// zoom can reach ultra-wide/telephoto, but only when it can actually deliver the
    /// requested format — see `bestDevice(position:quality:fps:)`.
    static let preferredDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera
    ]

    private let positionSettingsService: CameraPositionSettingsService

    init(positionSettingsService: CameraPositionSettingsService = CameraPositionSettingsService()) {
        self.positionSettingsService = positionSettingsService
    }

    /// Every camera available at `position`, richest first.
    ///
    /// `AVCaptureDevice.DiscoverySession.devices` is not guaranteed to respect
    /// `deviceTypes`' ordering, so preference order is applied explicitly.
    static func availableDevices(at position: AVCaptureDevice.Position) -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredDeviceTypes,
            mediaType: .video,
            position: position
        )
        let ordered = preferredDeviceTypes.compactMap { type in
            discovery.devices.first(where: { $0.deviceType == type })
        }
        // Anything the preference list didn't name still beats returning nothing.
        let remainder = discovery.devices.filter { device in
            !ordered.contains(where: { $0.uniqueID == device.uniqueID })
        }
        return ordered + remainder
    }

    /// The richest camera at `position` that can actually deliver `quality` at `fps`,
    /// falling back to the richest available when none can — so an unsupported request
    /// still degrades through `CameraService`'s existing fallback rather than failing.
    static func bestDevice(
        position: AVCaptureDevice.Position,
        quality: RecordingQuality,
        fps: RecordingFPS
    ) -> AVCaptureDevice? {
        let devices = availableDevices(at: position)
        return devices.first(where: { supports(quality: quality, fps: fps, device: $0) }) ?? devices.first
    }

    /// Whether `device` has a format at exactly `quality`'s pixel dimensions whose
    /// supported frame-rate ranges also cover `fps`. The pairing matters: a device can
    /// have 4K formats and 60fps formats and still have no format that is both.
    static func supports(quality: RecordingQuality, fps: RecordingFPS, device: AVCaptureDevice) -> Bool {
        let requestedRate = Double(fps.rawValue)
        return formats(on: device, matching: quality).contains { format in
            format.videoSupportedFrameRateRanges.contains {
                requestedRate >= $0.minFrameRate && requestedRate <= $0.maxFrameRate
            }
        }
    }

    static func formats(on device: AVCaptureDevice, matching quality: RecordingQuality) -> [AVCaptureDevice.Format] {
        let target = quality.dimensions
        return device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dimensions.width) == target.width && Int(dimensions.height) == target.height
        }
    }

    private var currentPosition: AVCaptureDevice.Position {
        positionSettingsService.load().selectedPosition == .front ? .front : .back
    }

    /// Whether *any* camera the app would consider binding at the current position has
    /// a format at `quality`'s dimensions. If no device can be looked up at all,
    /// returns `true` rather than disabling every option — `CameraService` will still
    /// resolve and report a fallback at actual configuration time either way.
    func isSupported(_ quality: RecordingQuality) -> Bool {
        let devices = Self.availableDevices(at: currentPosition)
        guard !devices.isEmpty else { return true }
        return devices.contains { !Self.formats(on: $0, matching: quality).isEmpty }
    }

    /// Whether *any* camera the app would consider binding at the current position
    /// supports `quality` at `fps`.
    ///
    /// Task 049: checked across every candidate device, not just the wide-angle one.
    /// That is the fix for 4K60 being wrongly reported unsupported — the answer has to
    /// cover the same set of devices `bestDevice(position:quality:fps:)` may choose
    /// from, or Settings blocks a combination the app would happily have bound a
    /// different camera for.
    func isSupported(_ fps: RecordingFPS, at quality: RecordingQuality) -> Bool {
        let devices = Self.availableDevices(at: currentPosition)
        guard !devices.isEmpty else { return true }
        return devices.contains { Self.supports(quality: quality, fps: fps, device: $0) }
    }

    #if DEBUG
    /// Task 049: dumps the real `AVCaptureDevice.formats` search, so the capability
    /// decision can be read off actual device data rather than reasoned about. Prints
    /// every candidate device and, per requested resolution, the frame-rate ranges its
    /// matching formats actually advertise — plus the verdict Settings will show.
    func logCapabilityDump() {
        let position = currentPosition
        let devices = Self.availableDevices(at: position)
        print("[Task049-Caps] position=\(position == .front ? "front" : "back") candidateDevices=\(devices.count)")

        for device in devices {
            print("[Task049-Caps]   device=\(device.deviceType.rawValue) totalFormats=\(device.formats.count)")
            for quality in RecordingQuality.allCases {
                let matching = Self.formats(on: device, matching: quality)
                let ranges = matching
                    .flatMap(\.videoSupportedFrameRateRanges)
                    .map { "\(Int($0.minFrameRate))-\(Int($0.maxFrameRate))" }
                    .joined(separator: ",")
                let verdicts = RecordingFPS.allCases
                    .map { "\($0.rawValue)fps=\(Self.supports(quality: quality, fps: $0, device: device) ? "YES" : "no")" }
                    .joined(separator: " ")
                print("[Task049-Caps]     \(quality.title) matchingFormats=\(matching.count) ranges=[\(ranges)] \(verdicts)")
            }
        }

        for quality in RecordingQuality.allCases {
            for fps in RecordingFPS.allCases {
                let verdict = isSupported(fps, at: quality) ? "선택 가능" : "차단됨"
                print("[Task049-Caps]   SETTINGS-VERDICT \(quality.title) @\(fps.rawValue)fps -> \(verdict)")
            }
        }
    }
    #endif
}
