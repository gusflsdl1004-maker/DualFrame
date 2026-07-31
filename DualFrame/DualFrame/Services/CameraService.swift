//
//  CameraService.swift
//  DualFrame
//

import AVFoundation
import Synchronization

enum CameraServiceError: Error {
    case deviceUnavailable
    case cannotAddInput
    case cannotAddOutput
    /// Task 027 requirement 3: switching cameras while a recording is in progress is
    /// never allowed — the UI already disables the toggle button while recording, and
    /// this is the defense-in-depth check inside `CameraService` itself.
    case cannotSwitchWhileRecording
    /// Task 091: the session refused the photo output at `configure()` time, so photo
    /// mode is unavailable for this launch. Recording is unaffected.
    case photoOutputUnavailable
    /// Refused on purpose — see `capturePhoto(flashMode:)`.
    case photoCaptureWhileRecording
    case photoCaptureFailed
}

/// Bridges `AVCapturePhotoOutput`'s delegate callback to an `async` result.
///
/// A separate object per capture, retained by `CameraService` for the duration: the
/// output holds its delegate weakly, and a deallocated delegate means the callback never
/// arrives and the photo is silently lost.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Result<(data: Data, fileExtension: String), Error>) -> Void
    private var hasCompleted = false

    init(completion: @escaping (Result<(data: Data, fileExtension: String), Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // AVFoundation can deliver more than one callback for a single capture; resuming
        // a continuation twice traps. Guarded rather than assumed.
        guard !hasCompleted else { return }
        hasCompleted = true

        if let error {
            completion(.failure(error))
            return
        }
        // `fileDataRepresentation()` is the complete container — EXIF (capture time,
        // dimensions, orientation, lens) is already inside it, so writing these bytes
        // straight to disk preserves the metadata without this app assembling any of it.
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(CameraServiceError.photoCaptureFailed))
            return
        }
        // Task 093: the extension follows what was actually encoded, read back off the
        // photo itself. The previous version guessed from the output's *available* codec
        // list, which says what the device can do, not what this capture did — so a JPEG
        // taken on an HEIF-capable device was being written as `.heic`.
        let isHEIF = photo.fileDataRepresentation().flatMap { data -> Bool? in
            // HEIF containers begin with an `ftyp` box; JPEG begins with 0xFFD8.
            guard data.count >= 12 else { return nil }
            return !(data[0] == 0xFF && data[1] == 0xD8)
        } ?? false
        completion(.success((data, isHEIF ? "heic" : "jpg")))
    }
}

/// Owns the capture session: camera/microphone inputs for a live preview, plus the
/// video/audio data outputs that feed sample buffers to `RecordingService`.
///
/// `startRunning`/`stopRunning` block the calling thread, so this type is its own actor
/// to keep that work off the main thread.
actor CameraService {
    // AVCaptureSession is safe to run from a background context while a preview layer
    // on the main thread holds the same reference (this mirrors Apple's AVCam sample).
    // Marked `nonisolated(unsafe)` so `CameraPreviewRepresentable` can bind it without awaiting.
    nonisolated(unsafe) let session = AVCaptureSession()

    /// The quality actually in effect after resolving the user's preference against
    /// what the device supports (see `selectFormat(quality:fps:device:)`).
    private(set) var activeQuality: RecordingQuality = .fullHD
    /// True if `activeQuality` differs from the user's selected preference because
    /// the requested quality wasn't supported.
    private(set) var qualityFallbackOccurred = false
    /// The frame rate actually in effect after resolving the user's preference against
    /// what the active format supports (see `selectFormat(quality:fps:device:)`).
    private(set) var activeFPS: RecordingFPS = .fps30
    /// True if `activeFPS` differs from the user's selected preference — either the
    /// rate itself was unsupported, or the resolved recording quality's format
    /// doesn't support it (requirement 8: quality + FPS compatibility).
    private(set) var fpsFallbackOccurred = false

    /// Task 043: the zoom factor actually applied to `videoDevice` right now — 1.0 is
    /// always the wide (primary) lens, values below 1.0 are the ultra-wide lens (when
    /// present), values above the switch-over point are the telephoto lens (when
    /// present). Reset to 1.0 whenever the device changes (`configure()`,
    /// `switchCamera(to:)`) — never touched by `refreshRecordingFormat()`, so a
    /// quality/FPS refresh right before recording can never snap the user's chosen
    /// zoom back to 1x.
    private(set) var currentZoomFactor: CGFloat = 1.0
    /// The lowest `videoZoomFactor` `videoDevice` currently accepts — below 1.0 only
    /// when an ultra-wide lens is part of the active (virtual) device.
    private(set) var minZoomFactor: CGFloat = 1.0
    /// The highest `videoZoomFactor` `videoDevice` currently accepts, including
    /// digital zoom beyond the last physical lens (requirement 4).
    private(set) var maxZoomFactor: CGFloat = 1.0
    /// Task 044: the raw `videoZoomFactor` that the user thinks of as "1×" — the wide
    /// lens. Not always 1.0: see `baseZoomFactor(for:)`.
    private(set) var baseZoomFactor: CGFloat = 1.0
    /// Quick-select buttons for the lenses `videoDevice` actually has (requirement 5)
    /// — always just `["1"]` for a single-lens device (e.g. iPhone SE).
    private(set) var zoomOptions: [CameraZoomOption] = [CameraZoomOption(id: "wide", factor: 1.0, label: "1")]


    #if DEBUG
    /// Task 057: hands the write off so a diagnostic can never stall camera
    /// configuration or the recording path. See `RecordingService.debugLog`.
    nonisolated func debugLog(_ message: String) {
        Task.detached(priority: .utility) { print(message) }
    }
    #endif

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    /// Task 091: added once, in `configure()`, inside the transaction that is already
    /// open there. Never touched again — see the comment at the call site.
    private let photoOutput = AVCapturePhotoOutput()
    /// False when the session refused the photo output, so the UI can say photo mode is
    /// unavailable instead of offering a shutter that does nothing.
    private(set) var isPhotoOutputAvailable = false
    /// Retained for the duration of a capture: `AVCapturePhotoOutput` does not keep its
    /// delegate alive, and a deallocated delegate means the callback never arrives and
    /// the photo is silently lost.
    private var photoCaptureDelegates: [Int64: PhotoCaptureDelegate] = [:]
    /// Task 063 item 5 (`FrameWasLate` → delegate queue backlog): **video and audio no
    /// longer share one queue.**
    ///
    /// Both outputs were previously given the same serial `DispatchQueue`. AVFoundation
    /// serialises delegate callbacks per queue, so every audio callback — and at 4K60
    /// there are tens of them a second — occupied the same queue the video callback has
    /// to run on. A video frame that becomes ready while an audio block is executing has
    /// to wait for it, and "the delegate has not returned yet" is precisely the
    /// condition AVFoundation reports as `FrameWasLate`. Against a 16.67ms budget there
    /// is no room for that wait.
    ///
    /// Task 052 split the *AsyncStreams* so a slow video consumer could not block audio
    /// delivery, but the dispatch queue underneath them stayed shared — the two
    /// delegates still ran one at a time. This finishes that split at the layer where
    /// AVFoundation actually measures lateness. Apple's own capture samples use a
    /// dedicated queue per output for the same reason.
    ///
    /// The explicit `.userInitiated` QoS is the second half: a queue created without one
    /// gets `.unspecified` and infers its priority from whoever submits to it, which
    /// leaves the video callback's priority up to AVFoundation's internals and lets it
    /// be preempted by ordinary default-priority work. Feeding a live 60fps recorder is
    /// user-initiated by definition.
    ///
    /// Serial (not concurrent) on purpose: the delegate must still see frames in order,
    /// and `AVCaptureVideoDataOutput` requires a serial queue.
    private let videoSampleBufferQueue = DispatchQueue(
        label: "com.dualframe.camera.videoSampleBufferQueue",
        qos: .userInitiated
    )
    private let audioSampleBufferQueue = DispatchQueue(
        label: "com.dualframe.camera.audioSampleBufferQueue",
        qos: .userInitiated
    )
    private let outputForwarder: SampleBufferOutputForwarder
    private let recordingService: RecordingService
    private let qualitySettingsService: RecordingQualitySettingsService
    private let fpsSettingsService: RecordingFPSSettingsService
    private let positionSettingsService: CameraPositionSettingsService
    /// Task 063 item 4: read fresh on every `applyFullSizeBufferDelivery()` — which runs
    /// before each recording — so flipping the switch in 진단 takes effect on the very
    /// next recording without restarting the app or rebuilding the session.
    private let lateFrameHandlingSettingsService: LateFrameHandlingSettingsService
    /// Task 022: the only source of orientation/mirroring decisions — this type never
    /// computes either itself (requirement 2).
    private let orientationManager: OrientationManager

    private var videoDevice: AVCaptureDevice?
    private var isConfigured = false

    /// The camera currently active, derived from `videoDevice` rather than tracked
    /// separately — there is exactly one source of truth for which device is in use.
    var currentPosition: CameraPosition {
        videoDevice?.position == .front ? .front : .back
    }

    /// `CameraPosition` stays free of AVFoundation (matches `RecordingQuality`'s
    /// pattern) — this is the one place that maps it to `AVCaptureDevice.Position`.
    private func avCapturePosition(for position: CameraPosition) -> AVCaptureDevice.Position {
        switch position {
        case .back: .back
        case .front: .front
        }
    }

    /// `orientationManager` has no default value on purpose — it's `@MainActor`
    /// (see the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` history of
    /// default-parameter isolation errors), so it must be constructed by the caller
    /// and passed in explicitly, same as `CameraPreviewView` already does for every
    /// other shared dependency.
    init(
        recordingService: RecordingService,
        orientationManager: OrientationManager,
        qualitySettingsService: RecordingQualitySettingsService = RecordingQualitySettingsService(),
        fpsSettingsService: RecordingFPSSettingsService = RecordingFPSSettingsService(),
        positionSettingsService: CameraPositionSettingsService = CameraPositionSettingsService(),
        lateFrameHandlingSettingsService: LateFrameHandlingSettingsService = LateFrameHandlingSettingsService()
    ) {
        self.recordingService = recordingService
        self.orientationManager = orientationManager
        self.qualitySettingsService = qualitySettingsService
        self.fpsSettingsService = fpsSettingsService
        self.positionSettingsService = positionSettingsService
        self.lateFrameHandlingSettingsService = lateFrameHandlingSettingsService
        outputForwarder = SampleBufferOutputForwarder(
            recordingService: recordingService,
            performanceMonitor: recordingService.performanceMonitor,
            videoOutput: videoOutput,
            callbackQueueLabel: videoSampleBufferQueue.label
        )
    }

    func start() async throws {
        if !isConfigured {
            // Task 039: quality + FPS are now resolved together, directly against
            // device.formats, inside configure()'s call to applyDeviceSpecificSettings
            // — no separate configureFrameRate() step anymore.
            try await configure()
            // RecordingService's AVAssetWriter (and its recovery checkpoint) must
            // reflect the resolution/frame rate the session is actually running at,
            // not just the user's raw preference.
            await recordingService.updateRecordingFormat(quality: activeQuality, fps: activeFPS)
        }
        guard !session.isRunning else { return }
        session.startRunning()
        // Task 029: purely observational — logged after the fact, changes nothing
        // about `startRunning()`'s own behavior (requirement 6: "CameraService 동작"
        // stays exactly as it was).
        logStartupEvent("Session Started")
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    // MARK: - Photo capture (Task 091)

    /// Takes one still.
    ///
    /// **Touches no session configuration.** `capturePhoto(with:delegate:)` uses the
    /// output that `configure()` already added; there is no `beginConfiguration()` on this
    /// path and no format change. The video pipeline is not involved: the same session
    /// keeps delivering to `videoOutput` throughout.
    ///
    /// Refuses while recording. `AVCapturePhotoOutput` can technically capture during a
    /// video recording, but it may momentarily interrupt the capture pipeline to service
    /// the still — and a dropped or late frame in a recording is a cost this app does not
    /// pay for a secondary feature (CLAUDE.md rules 1-3). The shutter is a still shutter
    /// or a record button, never both at once.
    func capturePhoto(
        flashMode: AVCaptureDevice.FlashMode,
        quality: PhotoQuality
    ) async throws -> (data: Data, fileExtension: String) {
        guard isPhotoOutputAvailable else { throw CameraServiceError.photoOutputUnavailable }
        guard session.isRunning else { throw CameraServiceError.photoCaptureFailed }
        guard await recordingService.state != .recording else {
            throw CameraServiceError.photoCaptureWhileRecording
        }

        // Task 093 P1-4: HEIF when the setting asks for it and the device offers it,
        // JPEG otherwise. Checked per capture rather than cached, because
        // `availablePhotoCodecTypes` depends on the active format and the active format
        // changes with the recording quality setting.
        let usesHEIF = quality.prefersHEIF && photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let settings: AVCapturePhotoSettings = usesHEIF
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])

        // Never above the output's ceiling, which `configure()` raised to `.quality`.
        // Clamped rather than assigned outright so this stays correct even if that ceiling
        // is ever lowered — the throw it would otherwise cause is uncatchable.
        // `QualityPrioritization` is an `Int` enum ordered speed < balanced < quality, but
        // it is not `Comparable`, so the raw values are compared.
        let ceiling = photoOutput.maxPhotoQualityPrioritization
        settings.photoQualityPrioritization = quality.prioritization.rawValue <= ceiling.rawValue
            ? quality.prioritization
            : ceiling

        // Only ask for flash the device actually supports in this configuration, so an
        // unsupported mode cannot make the whole capture fail. The front camera has no
        // lamp, so `supportedFlashModes` is `[.off]` there and this is skipped —
        // `PhotoCaptureViewModel` does a screen flash instead.
        if photoOutput.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }

        // Task 092 P0-1: **`settings.maxPhotoDimensions` used to be set here, and that
        // is what crashed the app.**
        //
        // It was assigned `activeFormat.supportedMaxPhotoDimensions.last`. That is a
        // value the *format* supports, but the documented contract is that it must also
        // not exceed `AVCapturePhotoOutput.maxPhotoDimensions` — which this code never
        // set, so it stayed at the output's default. Asking for more than the output was
        // configured for raises `NSInvalidArgumentException`, and an Objective-C
        // exception cannot be caught in Swift: the process dies on the spot.
        //
        // That single line produced every symptom reported. The white flash is set
        // synchronously just before this call, so the last frame the compositor ever drew
        // was white; the app then died mid-capture. And the white screen on relaunch was
        // not persisted state — it is iOS replaying the app's cached launch snapshot,
        // which had been captured white.
        //
        // Task 093 P1-5: 최고화질 asks for the largest still available — the request Task
        // 092 removed — but constrained so it cannot repeat that crash.
        //
        // The value must satisfy *both* conditions at once: supported by the current
        // `activeFormat`, **and** no larger than `photoOutput.maxPhotoDimensions`. Task
        // 092 checked only the first and died on the second. So the candidates are
        // filtered by the ceiling and the largest survivor is taken; if nothing survives,
        // nothing is set and the capture runs at the format's default.
        //
        // This is also why it stays correct after a format change. `activeFormat` changes
        // whenever recording quality does (`refreshRecordingFormat()`), while the output's
        // ceiling was fixed at configure time — so the two can disagree, and the filter is
        // what makes that disagreement produce a smaller photo instead of an exception.
        // The other two quality settings do not set it at all.
        if quality.requestsMaximumDimensions, let device = videoDevice {
            let ceiling = photoOutput.maxPhotoDimensions
            let candidate = device.activeFormat.supportedMaxPhotoDimensions
                .filter { $0.width <= ceiling.width && $0.height <= ceiling.height }
                .max { ($0.width, $0.height) < ($1.width, $1.height) }
            if let candidate {
                settings.maxPhotoDimensions = candidate
            }
        }

        let uniqueID = settings.uniqueID
        let captured: (data: Data, fileExtension: String) = try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate { [weak self] result in
                // Resume first, release second: the delegate must outlive the callback.
                continuation.resume(with: result)
                Task { await self?.releasePhotoDelegate(uniqueID) }
            }
            photoCaptureDelegates[uniqueID] = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
        return captured
    }

    private func releasePhotoDelegate(_ uniqueID: Int64) {
        photoCaptureDelegates[uniqueID] = nil
    }

    /// Task 092 P1-1: whether the active camera actually has a flash lamp.
    ///
    /// False on every front camera. The UI needs this to know that "flash on" has to mean
    /// a screen flash rather than a lamp — otherwise the control claims to do something
    /// the hardware cannot.
    var hasHardwareFlash: Bool {
        guard let videoDevice else { return false }
        return videoDevice.hasFlash && photoOutput.supportedFlashModes.count > 1
    }

    /// Reads the current recording orientation from `OrientationManager` for whichever
    /// camera is active, and pushes the resulting transform to `RecordingService`
    /// (requirement 2: never computed here). Called once per recording, right before
    /// `prepareRecording()` (see `RecordingViewModel.startRecording()`), so a device
    /// rotation between recordings is picked up, while a rotation *during* an active
    /// recording is never read again and so has no effect on it (requirement 5/6).
    func refreshRecordingOrientation() async {
        guard let device = videoDevice else { return }
        let transform = await orientationManager.recordingTransform(for: device.position)
        await recordingService.updateRecordingTransform(transform)
    }

    /// Task 043 requirement 1: re-resolves quality/FPS against the device's actual
    /// formats and re-applies the result, exactly like `configure()`/`switchCamera(to:)`
    /// already do — but callable on demand, right before a recording starts.
    ///
    /// Root cause of the reported "4K selected, Full HD recorded" bug: `configure()`
    /// (which reads `RecordingQualitySettingsService`/`RecordingFPSSettingsService` and
    /// calls `applyDeviceSpecificSettings`) only ever runs once per app launch, gated by
    /// `isConfigured` — `start()`'s later calls are a no-op beyond `startRunning()`. A
    /// quality/FPS change made in Settings *after* the camera was already configured was
    /// therefore never pushed to `device.activeFormat` or to `RecordingService`, which
    /// kept using whatever was resolved the first time. FPS could look correct by
    /// coincidence (if it hadn't been the thing the user last changed) while resolution
    /// silently stayed stale — matching exactly what was seen on the real device.
    ///
    /// Mirrors `refreshRecordingOrientation()`'s "read fresh right before this
    /// recording, not once at camera setup" pattern (Task 022) — called once per
    /// recording from `RecordingViewModel.startRecording()`, right alongside it. Reuses
    /// `applyDeviceSpecificSettings` unchanged rather than duplicating its format-search
    /// logic (requirement: 필요 최소 범위만 수정).
    func refreshRecordingFormat() async {
        guard var device = videoDevice else { return }
        // Task 044 requirement 1: this runs while the session is already *running*
        // (unlike `configure()`, whose caller wraps it). Changing `activeFormat`/frame
        // durations on a live session outside a configuration block lets the session
        // re-resolve its own configuration around the change, which can silently
        // revert the frame duration just written — the suspected cause of "60fps
        // selected, 29.98fps recorded". Wrapping it makes the format and frame
        // duration commit atomically as one reconfiguration.
        // Task 045: the mirroring lookup's `await` is resolved *before* the
        // configuration transaction opens, so the transaction below contains no
        // suspension point and commits atomically.
        let shouldMirror = await orientationManager.shouldMirrorRecording(for: device.position)
        session.beginConfiguration()
        // Task 047: the bound device is only chosen in `configure()`, once per launch.
        // Since a device can be incapable of a given quality+FPS pairing entirely (a
        // virtual multi-lens device has no 4K60 format at all — see
        // `bestAvailableDevice(for:quality:fps:)`), a Settings change made after launch
        // has to be able to change *which device is bound*, not just its format —
        // otherwise the requested rate would silently fall back exactly as before.
        if let rebound = rebindDeviceIfNeeded() {
            device = rebound
        }
        applyFormatAndFrameRate(device: device)
        applyRecordingMirroring(device: device, shouldMirror: shouldMirror)
        session.commitConfiguration()
        await recordingService.updateRecordingFormat(quality: activeQuality, fps: activeFPS)
        #if DEBUG
        logFormatStage(device: device)
        #endif
    }

    #if DEBUG
    /// Task 044 requirement 1/2: the "설정 → Device" half of the requested
    /// stage-by-stage trace, printed once per recording right before the writer is
    /// built. The "SampleBuffer → Writer" half is printed by `RecordingService`
    /// (same `[Task044-Debug]` tag), and the final "File" stage is whatever the
    /// exported file's own metadata reports.
    private func logFormatStage(device: AVCaptureDevice) {
        let formatDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let minDuration = device.activeVideoMinFrameDuration
        let maxDuration = device.activeVideoMaxFrameDuration
        let minFPS = minDuration.seconds > 0 ? 1 / minDuration.seconds : 0
        let maxFPS = maxDuration.seconds > 0 ? 1 / maxDuration.seconds : 0
        let supportedRanges = device.activeFormat.videoSupportedFrameRateRanges
            .map { "\($0.minFrameRate)-\($0.maxFrameRate)" }
            .joined(separator: ",")

        debugLog("""
        [Task044-Debug] STAGE 1 SETTINGS  requestedQuality=\(qualitySettingsService.load().selectedQuality.title) requestedFPS=\(fpsSettingsService.load().selectedFPS.rawValue)
        [Task044-Debug] STAGE 2 RESOLVED  CameraService.activeQuality=\(activeQuality.title) (\(activeQuality.dimensions.width)x\(activeQuality.dimensions.height)) CameraService.activeFPS=\(activeFPS.rawValue) qualityFallback=\(qualityFallbackOccurred) fpsFallback=\(fpsFallbackOccurred)
        [Task044-Debug] STAGE 3 DEVICE    activeFormat=\(formatDimensions.width)x\(formatDimensions.height) supportedFrameRateRanges=[\(supportedRanges)] activeVideoMinFrameDuration=\(minDuration.value)/\(minDuration.timescale) (=\(String(format: "%.2f", minFPS))fps) activeVideoMaxFrameDuration=\(maxDuration.value)/\(maxDuration.timescale) (=\(String(format: "%.2f", maxFPS))fps)
        [Task044-Debug] STAGE 3 DEVICE    sessionPreset=\(session.sessionPreset.rawValue) formatDescription=\(device.activeFormat.formatDescription)
        [Task044-Debug] STAGE 4 OUTPUT    automaticallyConfiguresOutputBufferDimensions=\(videoOutput.automaticallyConfiguresOutputBufferDimensions) deliversPreviewSizedOutputBuffers=\(videoOutput.deliversPreviewSizedOutputBuffers) videoSettings=\(videoOutput.videoSettings ?? [:])
        """)

        if let connection = videoOutput.connection(with: .video) {
            // AVCaptureConnection's own videoMin/MaxFrameDuration are unavailable on
            // iOS — AVCaptureDevice.activeVideoMin/MaxFrameDuration (STAGE 3 above) is
            // the only frame-duration control on this platform, so there is no
            // separate connection-level rate that could be overriding it.
            debugLog("[Task044-Debug] STAGE 4 CONNECTION isActive=\(connection.isActive) isEnabled=\(connection.isEnabled) isVideoMirrored=\(connection.isVideoMirrored) (frame duration is device-level only on iOS)")
        }
    }
    #endif

    private func configure() async throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Task 027 requirement 1: no longer hardcoded — reads the user's persisted
        // choice (default `.back`, per `CameraPositionSettings.default`).
        let requestedPosition = positionSettingsService.load().selectedPosition
        // Task 043 requirement 3/5: previously always `.builtInWideAngleCamera` — a
        // single physical lens with no way to reach ultra-wide/telephoto at all. Using
        // the richest available *virtual* multi-camera device instead (same device
        // `AVCaptureDevice.videoZoomFactor` already transparently switches between
        // constituent lenses as it crosses each lens's zoom range) is what makes zoom
        // able to reach more than one lens in the first place; falls back to the plain
        // wide-angle camera on devices with only one rear lens (e.g. iPhone SE).
        // Task 047: the device is chosen against the requested quality/FPS, because a
        // virtual multi-lens device may not offer the combination at all (see
        // `bestAvailableDevice(for:quality:fps:)`).
        guard let device = Self.bestAvailableDevice(
            for: avCapturePosition(for: requestedPosition),
            quality: qualitySettingsService.load().selectedQuality,
            fps: fpsSettingsService.load().selectedFPS
        ) else {
            logStartupEvent("Camera Unavailable", detail: requestedPosition.title)
            throw CameraServiceError.deviceUnavailable
        }
        videoDevice = device
        let videoDeviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoDeviceInput) else {
            throw CameraServiceError.cannotAddInput
        }
        session.addInput(videoDeviceInput)

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioDeviceInput) {
            session.addInput(audioDeviceInput)
        } else {
            // Unchanged behavior: audio is still best-effort, never throws — this only
            // adds a visible breadcrumb for why a recording might end up with no audio.
            logStartupEvent("Audio Unavailable")
        }

        videoOutput.setSampleBufferDelegate(outputForwarder, queue: videoSampleBufferQueue)
        guard session.canAddOutput(videoOutput) else {
            throw CameraServiceError.cannotAddOutput
        }
        session.addOutput(videoOutput)
        applyFullSizeBufferDelivery()

        audioOutput.setSampleBufferDelegate(outputForwarder, queue: audioSampleBufferQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        // Task 091 P0-3: **the photo output is added here and nowhere else.**
        //
        // Inside this method's still-open transaction, before `start()` calls
        // `startRunning()`. It is never added, removed or reconfigured afterwards — no
        // `beginConfiguration()` on a live session for photos, ever. That rule exists
        // because Tasks 079 and 081 both shipped exactly that mistake for a *preview*
        // layer and both times it cost recording: a black camera and a dead record
        // button, then a freeze on the record button.
        //
        // Best-effort, like the audio input above: if the session refuses it, video
        // recording is completely unaffected and photo mode simply reports being
        // unavailable rather than the camera failing to start.
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            isPhotoOutputAvailable = true
        } else {
            logStartupEvent("Photo Output Unavailable")
        }

        await applyDeviceSpecificSettings(device: device)

        // Task 093: raise the photo output's ceilings, **after** `applyDeviceSpecificSettings`
        // has settled `activeFormat` and while this method's transaction is still open.
        //
        // Both of these are ceilings that per-capture settings are checked against, and
        // exceeding either raises the same uncatchable Objective-C exception that crashed
        // the app in Task 092:
        //
        //   • `maxPhotoQualityPrioritization` — a capture asking for `.quality` when the
        //     output is left at its `.balanced` default throws. 최고화질 needs `.quality`,
        //     so the ceiling has to be raised here or that setting cannot exist safely.
        //   • `maxPhotoDimensions` — the ceiling Task 092's crash exceeded. Read from the
        //     format that is now active, so the value is by construction one the format
        //     supports.
        //
        // Order matters: setting these before `applyDeviceSpecificSettings` would read a
        // format that is about to be replaced, which is a subtler version of the same bug.
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = largest
        }

        setUpZoomCapabilities(device: device)
        isConfigured = true
        logStartupEvent("Camera Configured", detail: requestedPosition.title)
        #if DEBUG
        // Task 051 item 2: dumped at launch, not only when the FPS settings screen is
        // opened — a normal run now captures the full device/format survey.
        DeviceCapabilityService().logCapabilityDump()
        debugLog("[Task049-Caps]   ACTUALLY-BOUND deviceType=\(device.deviceType.rawValue) uniqueID=\(device.uniqueID)")
        #endif
    }

    /// Task 044 requirement 2: the prime suspect for "device.activeFormat says
    /// 3840x2160 but the saved file is 1920x1080".
    ///
    /// `AVCaptureVideoDataOutput.automaticallyConfiguresOutputBufferDimensions`
    /// defaults to `true`, which lets AVFoundation choose the dimensions of the
    /// `CMSampleBuffer`s it hands to the delegate independently of the capture
    /// device's `activeFormat` — in practice it can deliver downscaled (often
    /// preview-sized) buffers. Every log this project added in Task 043 measured
    /// either end of that gap (the device format on one side, the writer's
    /// `AVVideoWidthKey` on the other) and both correctly said 4K, because the
    /// downscale happens *between* them, in the buffers themselves.
    ///
    /// Setting this to `false` (and explicitly opting out of preview-sized buffers)
    /// is what makes the data output deliver buffers at the active format's full
    /// dimensions. Must be set *after* the output is added to the session, and
    /// re-applied whenever the session is reconfigured — hence the call from both
    /// `configure()` and `applyDeviceSpecificSettings(device:)`.
    private func applyFullSizeBufferDelivery() {
        if videoOutput.deliversPreviewSizedOutputBuffers {
            videoOutput.deliversPreviewSizedOutputBuffers = false
        }
        videoOutput.automaticallyConfiguresOutputBufferDimensions = false

        // Task 063 item 4: no longer a constant. Task 055 hardcoded this to `false`
        // (queue late frames instead of discarding them) on the theory that discarding
        // was what produced the climbing `lateDropped` count. Every measurement taken
        // since was taken with `false`, so the record contains no comparison — the
        // hypothesis was never actually tested.
        //
        // It now comes from `LateFrameHandlingSettings`, whose default is back to
        // AVFoundation's own (`discard`), and the value in force is written into the
        // session's diagnostics so a result can never be read against the wrong setting.
        // Re-read here rather than cached, because this method runs from
        // `applyFormatAndFrameRate` before every recording.
        let handling = lateFrameHandlingSettingsService.load().mode
        videoOutput.alwaysDiscardsLateVideoFrames = handling.alwaysDiscardsLateVideoFrames
    }

    /// Task 029: writes to the same shared `RecordingDiagnosticsLogService` instance
    /// `RecordingService` owns, via the `recordingService` reference this type already
    /// holds — no new dependency, and purely observational (requirement 6: doesn't
    /// change what `CameraService` actually does, only records that it happened).
    /// Fire-and-forget, same reasoning as `RecordingService.logEvent`.
    private func logStartupEvent(_ stage: String, detail: String? = nil) {
        let logService = recordingService.diagnosticsLogService
        Task { await logService.log(stage, detail: detail) }
    }

    /// Task 027: resolves quality/FPS/mirroring for whichever `device` is currently
    /// active. Shared by `configure()` (first setup) and `switchCamera(to:)` (a later
    /// camera change), so the two never duplicate this logic.
    ///
    /// Task 039: previously this set `session.sessionPreset` to a resolution-only
    /// preset (e.g. `.hd4K3840x2160`) and then, in a separate step
    /// (`configureFrameRate()`), tried to force a frame rate via
    /// `activeVideoMinFrameDuration`/`activeVideoMaxFrameDuration` against whatever
    /// `AVCaptureDevice.Format` the session preset happened to auto-select. That's the
    /// root cause of "4K selected but recorded as HD" / "60fps selected but recorded
    /// as 30fps": when `sessionPreset != .inputPriority`, AVFoundation — not the app —
    /// owns `activeFormat`, and the specific format it silently picks for a given
    /// preset is not guaranteed to be the one (if any) that supports the requested
    /// frame rate, or even reliably the exact resolution the app assumed. The app was
    /// asking "can the session accept this preset" and "does whatever format the
    /// session already picked support this FPS" — never "does this device actually
    /// have a format matching resolution AND FPS together."
    ///
    /// Fixed by switching to `.inputPriority` (the app owns `activeFormat`) and
    /// directly searching `device.formats` for one whose dimensions and
    /// `videoSupportedFrameRateRanges` both match what the user selected — the actual
    /// device capability list, not a preset abstraction.
    private func applyDeviceSpecificSettings(device: AVCaptureDevice) async {
        applyFormatAndFrameRate(device: device)

        // Task 045: this `await` used to sit inside this method, which callers wrap in
        // `session.beginConfiguration()`/`commitConfiguration()`. On an actor an
        // `await` is a suspension point, so the capture session could sit in a
        // half-open configuration transaction while other actor methods interleaved —
        // exactly the kind of window in which AVFoundation can re-resolve the session
        // and discard the format/frame duration just written. Hoisted out so the
        // configuration transaction now contains no suspension points at all.
        applyRecordingMirroring(device: device, shouldMirror: await orientationManager.shouldMirrorRecording(for: device.position))
    }

    /// Task 047: swaps the session's video input to a device that can actually deliver
    /// the currently-requested quality+FPS, when the bound one cannot and another can.
    /// Returns the newly bound device, or `nil` if nothing changed.
    ///
    /// Caller must already be inside a `session.beginConfiguration()` transaction —
    /// this deliberately does not open its own, so the input swap and the
    /// format/frame-rate application that follows commit together as one
    /// reconfiguration rather than two.
    ///
    /// Only ever swaps between cameras on the *same* position: `avCapturePosition(for:)`
    /// is derived from the current device, so this never silently flips front/back.
    /// The zoom capability set is rebuilt for the new device, since its lens
    /// configuration differs by definition.
    private func rebindDeviceIfNeeded() -> AVCaptureDevice? {
        guard let currentDevice = videoDevice else { return nil }
        let quality = qualitySettingsService.load().selectedQuality
        let fps = fpsSettingsService.load().selectedFPS

        guard !Self.supportsExactly(quality: quality, fps: fps, device: currentDevice),
              let candidate = Self.bestAvailableDevice(for: currentDevice.position, quality: quality, fps: fps),
              candidate.uniqueID != currentDevice.uniqueID,
              Self.supportsExactly(quality: quality, fps: fps, device: candidate),
              let newInput = try? AVCaptureDeviceInput(device: candidate),
              let currentInput = session.inputs
                  .compactMap({ $0 as? AVCaptureDeviceInput })
                  .first(where: { $0.device.hasMediaType(.video) })
        else { return nil }

        session.removeInput(currentInput)
        guard session.canAddInput(newInput) else {
            // Put the working input back rather than leaving the session with no
            // camera — never lose the ability to record (CLAUDE.md priority 1/2).
            session.addInput(currentInput)
            return nil
        }
        session.addInput(newInput)
        videoDevice = candidate
        setUpZoomCapabilities(device: candidate)
        logStartupEvent("Camera Rebound", detail: candidate.deviceType.rawValue)
        return candidate
    }

    /// Task 045: the synchronous half of `applyDeviceSpecificSettings(device:)` —
    /// everything that must happen atomically inside one session configuration
    /// transaction, with no `await` anywhere in it.
    private func applyFormatAndFrameRate(device: AVCaptureDevice) {
        let requestedQuality = qualitySettingsService.load().selectedQuality
        let requestedFPS = fpsSettingsService.load().selectedFPS
        let selection = Self.selectFormat(quality: requestedQuality, fps: requestedFPS, device: device)

        session.sessionPreset = .inputPriority
        do {
            try device.lockForConfiguration()
            device.activeFormat = selection.format
            // Task 044 requirement 1: assigning `activeFormat` resets the device's
            // frame-duration properties to that format's defaults, so these must be
            // set *after* it — never before, or the requested rate is silently
            // discarded and the format's default (typically 30fps, reported as ~29.97)
            // is what actually gets captured.
            applyFrameDuration(selection.resolvedFPS, to: device)
            device.unlockForConfiguration()
            activeQuality = selection.resolvedQuality
            qualityFallbackOccurred = selection.qualityFallbackOccurred
            activeFPS = selection.resolvedFPS
            fpsFallbackOccurred = selection.fpsFallbackOccurred
        } catch {
            // lockForConfiguration itself failed (rare — e.g. device just disconnected).
            // Falls back to whatever format the device already has rather than leaving
            // activeQuality/activeFPS out of sync with reality.
            activeQuality = .fullHD
            qualityFallbackOccurred = true
            activeFPS = .fps30
            fpsFallbackOccurred = true
        }

        // Task 044 requirement 2: re-assert full-size buffer delivery after every
        // format change — AVFoundation resets output-buffer configuration when the
        // session/device format is reconfigured, so setting it once in `configure()`
        // is not enough.
        applyFullSizeBufferDelivery()
    }

    /// Task 045: pins both frame-duration bounds to `fps`. Factored out because it has
    /// to be re-applied at several points that each independently reset it —
    /// `activeFormat` assignment, and a virtual device switching constituent lens on a
    /// zoom change (`setZoomFactor(_:)`). Caller must already hold
    /// `lockForConfiguration()`.
    private func applyFrameDuration(_ fps: RecordingFPS, to device: AVCaptureDevice) {
        let frameDuration = CMTime(value: 1, timescale: Int32(fps.rawValue))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
    }

    /// Requirement 3/4 (Task 022, now actually exercised for a front camera too):
    /// the *recorded* connection must never mirror, regardless of AVFoundation's
    /// automatic-mirroring defaults. This only affects the data output feeding
    /// `RecordingService` — it doesn't touch the preview layer's own connection (no
    /// UI change beyond the toggle button itself).
    private func applyRecordingMirroring(device: AVCaptureDevice, shouldMirror: Bool) {
        guard let recordingConnection = videoOutput.connection(with: .video) else { return }
        recordingConnection.automaticallyAdjustsVideoMirroring = false
        recordingConnection.isVideoMirrored = shouldMirror
    }

    /// Task 027 requirement 3: switches the active camera. Only ever safe to call
    /// while nothing is recording — `RecordingService`'s writer(s) are never touched
    /// here (requirement 6: no writer recreation), since this can only run when no
    /// writer exists in the first place.
    func switchCamera(to position: CameraPosition) async throws {
        guard await recordingService.state != .recording else {
            throw CameraServiceError.cannotSwitchWhileRecording
        }
        guard currentPosition != position else { return }

        guard let newDevice = Self.bestAvailableDevice(
            for: avCapturePosition(for: position),
            quality: qualitySettingsService.load().selectedQuality,
            fps: fpsSettingsService.load().selectedFPS
        ) else {
            throw CameraServiceError.deviceUnavailable
        }
        let newInput = try AVCaptureDeviceInput(device: newDevice)

        guard let currentInput = session.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) }) else {
            throw CameraServiceError.deviceUnavailable
        }

        session.beginConfiguration()
        session.removeInput(currentInput)
        guard session.canAddInput(newInput) else {
            session.addInput(currentInput)
            session.commitConfiguration()
            throw CameraServiceError.cannotAddInput
        }
        session.addInput(newInput)
        session.commitConfiguration()

        videoDevice = newDevice
        await applyDeviceSpecificSettings(device: newDevice)
        // Task 043: the new camera can have an entirely different lens configuration
        // (e.g. the front camera has no ultra-wide/telephoto at all) — zoom options
        // and the current factor must be rebuilt for it, same reasoning as below for
        // quality/FPS.
        setUpZoomCapabilities(device: newDevice)
        // Task 039: the front/back camera can support a different resolution/FPS
        // combination — RecordingService's writer settings must follow whatever
        // applyDeviceSpecificSettings just resolved for the new device, not stay
        // pinned to whatever the previous camera was using.
        await recordingService.updateRecordingFormat(quality: activeQuality, fps: activeFPS)
        positionSettingsService.save(CameraPositionSettings(selectedPosition: position))
    }

    /// Task 045 requirement 3: applies a new zoom factor, clamped to what the device
    /// currently supports. The single place that touches
    /// `AVCaptureDevice.videoZoomFactor`, for every input mode.
    ///
    /// `animated` picks between the two behaviours Apple Camera itself uses:
    /// - `true` (quick-select lens buttons): `ramp(toVideoZoomFactor:withRate:)`, which
    ///   animates smoothly to the target instead of jump-cutting the framing.
    /// - `false` (pinch and slider drag): a direct assignment, because those must
    ///   track the user's finger frame-for-frame — ramping a continuous gesture would
    ///   lag behind and fight each successive update.
    ///
    /// Any zoom change can move a *virtual* device across a lens switch-over point,
    /// which re-selects the constituent lens and resets that device's frame-duration
    /// bounds — so the requested frame rate is re-pinned afterwards (Task 045
    /// requirement 2). Without this, zooming during a 60fps recording could silently
    /// drop the capture to the new lens's default rate.
    func setZoomFactor(_ factor: CGFloat, animated: Bool = false) {
        guard let device = videoDevice else { return }
        let clamped = min(max(factor, minZoomFactor), maxZoomFactor)
        let crossesLensSwitchOver = Self.crossesLensSwitchOver(
            from: currentZoomFactor,
            to: clamped,
            device: device
        )
        do {
            try device.lockForConfiguration()
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: Self.zoomRampRate)
            } else {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = clamped
            }
            if crossesLensSwitchOver {
                applyFrameDuration(activeFPS, to: device)
            }
            device.unlockForConfiguration()
            currentZoomFactor = clamped
        } catch {
            logStartupEvent("Zoom Configuration Failed")
        }
    }

    /// How fast `ramp(toVideoZoomFactor:withRate:)` moves, in powers of two per
    /// second. 4.0 covers a 0.5×→3× move in roughly half a second — close to Apple
    /// Camera's lens-button feel without being slow enough to miss a shot.
    private static let zoomRampRate: Float = 4.0

    /// Whether moving between two zoom factors crosses one of the device's
    /// constituent-lens switch-over points — i.e. whether the physical lens in use is
    /// about to change. Always `false` on a single-lens device, which has none.
    private nonisolated static func crossesLensSwitchOver(
        from oldFactor: CGFloat,
        to newFactor: CGFloat,
        device: AVCaptureDevice
    ) -> Bool {
        let lower = min(oldFactor, newFactor)
        let upper = max(oldFactor, newFactor)
        return device.virtualDeviceSwitchOverVideoZoomFactors
            .map { CGFloat(truncating: $0) }
            .contains { lower < $0 && $0 <= upper }
    }

    /// Task 044 requirement 3: rebuilds `zoomOptions`/`minZoomFactor`/`maxZoomFactor`/
    /// `baseZoomFactor` for `device` and resets the zoom to the *wide* lens — called
    /// only when `device` itself has just changed (`configure()`,
    /// `switchCamera(to:)`), deliberately never from `refreshRecordingFormat()`, so a
    /// quality/FPS refresh right before a recording can never reset the zoom level the
    /// user actually framed their shot with.
    ///
    /// Note the reset target is `baseZoomFactor`, not the literal `1.0` Task 043 used:
    /// on a virtual device that includes an ultra-wide lens, `videoZoomFactor == 1.0`
    /// is the *ultra-wide* (a "0.5×" view), so the old code silently started every
    /// session zoomed all the way out.
    private func setUpZoomCapabilities(device: AVCaptureDevice) {
        minZoomFactor = device.minAvailableVideoZoomFactor
        maxZoomFactor = device.maxAvailableVideoZoomFactor
        baseZoomFactor = Self.baseZoomFactor(for: device)
        zoomOptions = Self.zoomOptions(for: device)
        currentZoomFactor = baseZoomFactor
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = baseZoomFactor
            device.unlockForConfiguration()
        } catch {
            logStartupEvent("Zoom Reset Failed")
        }
        #if DEBUG
        let constituents = device.constituentDevices.map(\.deviceType.rawValue).joined(separator: ",")
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { "\($0)" }.joined(separator: ",")
        debugLog("""
        [Task044-Debug] ZOOM deviceType=\(device.deviceType.rawValue) constituentDevices=[\(constituents)] virtualDeviceSwitchOverVideoZoomFactors=[\(switchOvers)]
        [Task044-Debug] ZOOM minAvailable=\(minZoomFactor) maxAvailable=\(maxZoomFactor) baseZoomFactor(1x)=\(baseZoomFactor) buttons=\(zoomOptions.map { "\($0.label)x@\($0.factor)" }.joined(separator: " "))
        """)
        #endif
    }

    /// The camera to bind for `position`, preferring richer multi-lens devices (triple
    /// → dual-wide → dual → single wide) so zoom can reach ultra-wide/telephoto.
    ///
    /// Task 047: **now format-aware**, which is the fix for "60FPS selected, 30fps
    /// recorded". The real-device log proved the cause:
    ///
    ///     ZOOM  deviceType=AVCaptureDeviceTypeBuiltInDualWideCamera
    ///     STAGE 3 DEVICE  activeFormat=3840x2160
    ///                     supportedFrameRateRanges=[2.0-30.0]
    ///
    /// A *virtual* multi-lens device exposes a restricted format list — it has to
    /// support seamless switching between its constituent lenses — and on this device
    /// its 4K formats top out at 30fps, even though the standalone
    /// `.builtInWideAngleCamera` supports 4K60. Task 043 switched from the wide-angle
    /// camera to the richest virtual device purely to enable multi-lens zoom, and in
    /// doing so silently removed 4K60 from the reachable format list. Everything
    /// downstream then behaved correctly and honestly: `selectFormat` reported
    /// `fpsFallback=true`, and the 30fps propagated all the way to the file.
    ///
    /// So the choice of device and the choice of format are not independent, and
    /// picking the device first — as this used to — cannot be right. This now returns
    /// the richest device that can *actually deliver* the requested quality+FPS, and
    /// only falls back to "richest available regardless" when no device can (so an
    /// unsupported request still degrades exactly as before rather than failing).
    ///
    /// Trade-off, per CLAUDE.md's ordering (recording correctness over UI/features):
    /// when the requested combination is only available on the single-lens camera, the
    /// user gets the resolution and frame rate they asked for and loses the extra lens
    /// buttons for that session. `zoomOptions` already derives itself from whichever
    /// device is bound, so the UI follows automatically.
    /// Task 049: delegates to `DeviceCapabilityService`, which is now the single
    /// implementation of both "which camera" and "can it do this format". This method
    /// previously carried its own private copy of that search, and the Settings screens
    /// carried a third, narrower one — which is exactly how Settings and capture came
    /// to disagree about 4K60.
    private nonisolated static func bestAvailableDevice(
        for position: AVCaptureDevice.Position,
        quality: RecordingQuality,
        fps: RecordingFPS
    ) -> AVCaptureDevice? {
        DeviceCapabilityService.bestDevice(position: position, quality: quality, fps: fps)
    }

    private nonisolated static func supportsExactly(
        quality: RecordingQuality,
        fps: RecordingFPS,
        device: AVCaptureDevice
    ) -> Bool {
        DeviceCapabilityService.supports(quality: quality, fps: fps, device: device)
    }

    /// Task 044 requirement 3: the raw `videoZoomFactor` that corresponds to the
    /// **wide** lens — i.e. what a user calls "1×".
    ///
    /// This is the correction at the heart of the "only 2 zoom buttons" bug. On a
    /// virtual multi-lens device, `videoZoomFactor` is expressed relative to the
    /// *widest constituent lens*, not the wide one. On a triple-camera iPhone the
    /// ultra-wide is the base, so `videoZoomFactor == 1.0` is the "0.5×" view and the
    /// wide lens actually begins at `virtualDeviceSwitchOverVideoZoomFactors[0]`
    /// (typically 2.0). Task 043 assumed 1.0 was always the wide lens, so it emitted
    /// an ultra-wide button labelled "1" *and* a hardcoded wide button also labelled
    /// "1" — duplicate, wrongly-labelled entries instead of the expected 0.5/1/3.
    ///
    /// When there's no ultra-wide constituent the device already starts at the wide
    /// lens, so the base is simply 1.0.
    private nonisolated static func baseZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        guard device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
              let firstSwitchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first else {
            return 1.0
        }
        return CGFloat(truncating: firstSwitchOver)
    }

    /// Task 044 requirement 3: one quick-select button per lens the device actually
    /// has, labelled the way a user expects (0.5 / 1 / 2 / 3 …) rather than in raw
    /// `videoZoomFactor` units.
    ///
    /// Derived entirely from the device's own capability data — never a hardcoded list
    /// of models: the ultra-wide (when present) sits at `minAvailableVideoZoomFactor`,
    /// and *every* entry in `virtualDeviceSwitchOverVideoZoomFactors` marks where the
    /// next physical lens takes over, so a device with more lenses automatically gets
    /// more buttons. Task 043 only ever looked at the single largest switch-over
    /// factor, which is why intermediate lenses went missing.
    ///
    /// A 2× button is added on top when the device can reach it but has no physical
    /// lens there — the same digital-crop convenience button Apple's Camera app shows
    /// on Pro models.
    /// Task 072 P0-3: the zoom buttons a given device can actually deliver.
    ///
    /// **The bug this replaces:** the old version bailed out to a single "1" button
    /// whenever `constituentDevices` was empty. That is exactly the case on a standalone
    /// `.builtInWideAngleCamera` — which is the device Task 047 binds for 4K60, because
    /// the virtual multi-lens devices cap 4K at 30fps. So choosing 4K60 silently reduced
    /// the zoom UI to one inert button.
    ///
    /// A single-lens device still zooms; it just does it digitally, and Apple's own
    /// Camera offers those steps too. Physical lens switch-over points are added on top
    /// when the device is virtual, so a triple-camera gets its real optical stops rather
    /// than digital approximations of them.
    ///
    /// Everything is filtered against `min`/`maxAvailableVideoZoomFactor`, so a factor
    /// the hardware cannot reach is never offered (requirement: 지원하지 않는 배율은 숨김).
    private nonisolated static func zoomOptions(for device: AVCaptureDevice) -> [CameraZoomOption] {
        let base = baseZoomFactor(for: device)
        let minFactor = device.minAvailableVideoZoomFactor
        let maxFactor = device.maxAvailableVideoZoomFactor

        var factors: [CGFloat] = []

        // Ultra-wide, only when the device can genuinely go below 1x. On a standalone
        // wide camera `minAvailableVideoZoomFactor` is 1.0, so this contributes nothing
        // rather than offering a 0.5x that would just crop.
        if minFactor < base {
            factors.append(minFactor)
        }

        factors.append(base)

        // Real optical stops on a virtual device.
        factors.append(contentsOf: device.virtualDeviceSwitchOverVideoZoomFactors
            .map { CGFloat(truncating: $0) }
            .filter { $0 > base })

        // Digital steps, matching the ladder Apple Camera shows. Each is only added when
        // the hardware reaches it *and* no physical lens already sits within 5% of it —
        // otherwise a triple-camera would show both its optical 2x and a digital 2x.
        // Task 073 P0-3: digital steps stop at 5×. Beyond that the button row gets
        // crowded and the result is heavily interpolated — 10× and above stay reachable
        // by pinch, which is where a user reaching for extreme zoom already goes.
        // Optical stops are added above regardless of this cap, so a device with a
        // physical 10× lens still gets its button.
        for multiplier in [CGFloat(2), 3, 5] {
            let candidate = base * multiplier
            guard candidate <= maxFactor else { continue }
            guard !factors.contains(where: { abs($0 - candidate) < candidate * 0.05 }) else { continue }
            factors.append(candidate)
        }

        return factors
            .filter { $0 >= minFactor && $0 <= maxFactor }
            .sorted()
            .map { factor in
                CameraZoomOption(
                    id: "zoom-\(factor)",
                    factor: factor,
                    label: formattedFactor(factor / base)
                )
            }
    }

    /// "0.5" / "1" / "3" — one decimal place, trailing ".0" dropped, matching how
    /// Apple's own Camera app labels its lens buttons. Takes an already
    /// base-normalised (user-facing) value, not a raw `videoZoomFactor`.
    private nonisolated static func formattedFactor(_ factor: CGFloat) -> String {
        let rounded = (factor * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }

    /// Task 039: replaces the old `resolveSessionPreset`/`configureFrameRate` pair.
    /// Searches `device.formats` directly — the actual list of capture formats this
    /// device supports — for one matching `quality`'s pixel dimensions whose
    /// `videoSupportedFrameRateRanges` also covers `fps`. Falls back first to a lower
    /// resolution (same ordering as before: 4K → Full HD → HD), and within whichever
    /// resolution is chosen, falls back to the highest FPS that resolution's matching
    /// formats actually support if `fps` itself isn't available there.
    ///
    /// `nonisolated` — reads no actor state, only queries `device` (an `AVCaptureDevice`
    /// reference, safe to query off-actor). `DeviceCapabilityService` (used by the
    /// Settings screens for requirement 5) applies the same dimension/frame-rate
    /// matching independently, since it has no reason to depend on a live
    /// `CameraService` instance — it only needs a fresh `AVCaptureDevice` reference.
    private nonisolated static func selectFormat(
        quality: RecordingQuality,
        fps: RecordingFPS,
        device: AVCaptureDevice
    ) -> (format: AVCaptureDevice.Format, resolvedQuality: RecordingQuality, resolvedFPS: RecordingFPS, qualityFallbackOccurred: Bool, fpsFallbackOccurred: Bool) {
        let orderedQualities: [RecordingQuality] = [.uhd4K, .fullHD, .hd]
        let startIndex = orderedQualities.firstIndex(of: quality) ?? 0

        for candidateQuality in orderedQualities[startIndex...] {
            let matchingFormats = formats(on: device, matching: candidateQuality)
            guard !matchingFormats.isEmpty else { continue }

            let requestedRate = Double(fps.rawValue)
            if let exactFormat = matchingFormats.first(where: { format in
                format.videoSupportedFrameRateRanges.contains { requestedRate >= $0.minFrameRate && requestedRate <= $0.maxFrameRate }
            }) {
                return (exactFormat, candidateQuality, fps, candidateQuality != quality, false)
            }

            // This resolution exists, but no format at it supports the requested FPS —
            // use whichever matching format supports the highest frame rate instead.
            let bestFormat = matchingFormats.max { a, b in
                (a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                    < (b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            }
            if let bestFormat {
                let maxRate = bestFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? Double(RecordingFPS.fps30.rawValue)
                let fallbackFPS = RecordingFPS.allCases
                    .filter { Double($0.rawValue) <= maxRate }
                    .max(by: { $0.rawValue < $1.rawValue }) ?? .fps30
                return (bestFormat, candidateQuality, fallbackFPS, candidateQuality != quality, true)
            }
        }

        // No candidate resolution matched anything in device.formats — extremely
        // unlikely (every iPhone camera supports at least HD), but fall back to
        // whatever format the device is already using rather than crashing.
        return (device.activeFormat, .hd, .fps30, true, true)
    }

    /// Task 039 requirement 2: the actual query against device capabilities — matches
    /// `AVCaptureDevice.Format.formatDescription`'s pixel dimensions against `quality`,
    /// not a session-preset abstraction. Task 049: now the shared implementation, so
    /// `selectFormat` and the Settings screens can never diverge.
    private nonisolated static func formats(on device: AVCaptureDevice, matching quality: RecordingQuality) -> [AVCaptureDevice.Format] {
        DeviceCapabilityService.formats(on: device, matching: quality)
    }
}

/// Forwards sample buffers from the capture outputs to `RecordingService`.
/// A plain `NSObject` because `AVCapture...SampleBufferDelegate` callbacks arrive
/// synchronously on a dispatch queue, outside of Swift actor isolation.
/// `nonisolated` to opt out of this project's default main-actor isolation — the delegate
/// methods must run on the capture queue, not the main actor.
private nonisolated final class SampleBufferOutputForwarder: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Task 054: a buffer plus the timestamps taken on the capture queue, carried
    /// through the stream so the consumer can measure the hand-off without reading any
    /// delegate-owned state across threads.
    private struct TimedBuffer {
        let buffer: CMSampleBuffer
        #if DEBUG
        /// 1. `captureOutput(_:didOutput:)` entry.
        let capturedAt: Date
        /// 2. immediately before `yield`.
        let yieldedAt: Date
        /// Task 057 item 2: assigned on the capture queue and carried *by value*, so
        /// the consumer can derive in-flight depth without reading a counter the
        /// capture thread is concurrently mutating. Reading `videoYieldedTotal` across
        /// threads is what produced `inFlight=-1` / `released > yielded`: the two
        /// counters were sampled at different instants, not a real double release.
        let sequence: Int
        #endif
    }

    private let recordingService: RecordingService
    private let performanceMonitor: RecordingPerformanceMonitor

    /// Task 067: how many video buffers this code is holding right now — yielded to the
    /// stream but not yet released by the consumer. Read inside `didDrop` to answer
    /// "was our side backed up at the moment AVFoundation gave up on a frame".
    ///
    /// Atomic rather than the Debug-only `videoYieldedTotal`/`videoReleasedTotal` pair,
    /// for two reasons: this has to work in Release (that is where the symptom is), and
    /// those two counters are written from different threads and sampled at different
    /// instants, which is exactly what produced the bogus `inFlight = -1` readings noted
    /// in Task 057. One atomic, relaxed ordering — a counter with no other invariant
    /// riding on it, so relaxed is sufficient and costs essentially nothing per frame.
    private let inFlightVideoBuffers = Atomic<Int>(0)

    private let videoContinuation: AsyncStream<TimedBuffer>.Continuation
    private let audioContinuation: AsyncStream<CMSampleBuffer>.Continuation
    /// `var` because the consumers capture `self` (for the Debug delivery stats), so
    /// they can only be created after `super.init()`.
    private var videoConsumer: Task<Void, Never>?
    private var audioConsumer: Task<Void, Never>?


    #if DEBUG
    /// Task 057: same reasoning as `RecordingService.debugLog` — `debugLog()` writes
    /// synchronously to the debug connection. The `[Task054-Capture]` line runs on the
    /// capture delegate queue, so blocking there delays AVFoundation's own callback and
    /// makes it discard the next frame. Diagnostics must never do that.
    private nonisolated func debugLog(_ message: String) {
        Task.detached(priority: .utility) { print(message) }
    }
    #endif

    private static let flushInterval = 30

    /// Task 055 items 3/4/5: **the fix.**
    ///
    /// Every queued `CMSampleBuffer` keeps a `CVPixelBuffer` checked out of
    /// `AVCaptureVideoDataOutput`'s internal pool, and that pool is small and fixed. At
    /// 4K a depth of 12 (set in Task 047b) meant holding up to twelve pool slots at all
    /// times, so the pool ran dry and AVFoundation had nowhere to render the next frame
    /// — which is precisely what it reports as a late drop.
    ///
    /// The depth was chosen to absorb a slow consumer, but Task 053 measured the
    /// consumer at ~2ms per frame against a 16.67ms budget. It was never slow, so the
    /// queue bought nothing and cost pool slots continuously. Two is enough to cover
    /// one frame in flight plus one arriving.
    private static let videoBufferDepth = 2

    #if DEBUG
    /// Delegate-side stats. Written only inside `captureOutput`'s *video* branch, which
    /// AVFoundation serialises on the video callback queue, so there is exactly one
    /// writer and no cross-thread access — the consumer never reads these.
    /// Task 063: audio callbacks now arrive on a separate queue and so can run
    /// concurrently with the video ones, but the audio branch touches none of these —
    /// it only yields to `audioContinuation`, which is itself thread-safe.
    private nonisolated(unsafe) var lastCallbackEntry: Date?
    private nonisolated(unsafe) var callbackCount = 0
    private nonisolated(unsafe) var intervalTotal: TimeInterval = 0
    private nonisolated(unsafe) var intervalMax: TimeInterval = 0
    private nonisolated(unsafe) var executionTotal: TimeInterval = 0
    private nonisolated(unsafe) var executionMax: TimeInterval = 0
    private nonisolated(unsafe) var yieldDelayTotal: TimeInterval = 0
    private nonisolated(unsafe) var yieldDropped = 0
    private nonisolated(unsafe) var didLogConfiguration = false
    private nonisolated(unsafe) var lateDropCount = 0
    /// Task 055 items 3/4/5: pool pressure. `videoYieldedTotal` is written only on the
    /// capture queue and `videoReleasedTotal` only on the consumer, so each has one
    /// writer; the difference is how many capture-pool buffers this code is holding at
    /// that instant. If the late drops were caused by us starving the pool, this is the
    /// number that has to come down.
    private nonisolated(unsafe) var videoYieldedTotal = 0
    private nonisolated(unsafe) var videoReleasedTotal = 0
    private nonisolated(unsafe) var inFlightMax = 0
    private nonisolated(unsafe) var didLogPool = false

    /// Consumer-side stats. Written only inside the single video consumer task.
    private var deliveryCount = 0
    private var streamLatencyTotal: TimeInterval = 0
    private var streamLatencyMax: TimeInterval = 0
    private var preAppendTotal: TimeInterval = 0
    private var endToEndTotal: TimeInterval = 0
    private var endToEndMax: TimeInterval = 0
    /// Item 4: how long each capture buffer stays alive in our hands — capture-queue
    /// entry until the moment we drop the last reference to it.
    private var lifetimeTotal: TimeInterval = 0
    private var lifetimeMax: TimeInterval = 0
    private var consumerInFlightMax = 0
    /// Item 1: frames whose buffer stayed alive far longer than a frame interval, which
    /// is the population worth explaining — the average hides them.
    private var slowBufferCount = 0
    private var slowBufferWorstMs: Double = 0
    #endif

    /// Kept so the configuration dump can report what AVFoundation was actually
    /// configured with, rather than what the code intended.
    private weak var videoOutput: AVCaptureVideoDataOutput?
    private let callbackQueueLabel: String

    init(
        recordingService: RecordingService,
        performanceMonitor: RecordingPerformanceMonitor,
        videoOutput: AVCaptureVideoDataOutput? = nil,
        callbackQueueLabel: String = "unknown"
    ) {
        self.recordingService = recordingService
        self.performanceMonitor = performanceMonitor
        self.videoOutput = videoOutput
        self.callbackQueueLabel = callbackQueueLabel

        let (videoStream, videoContinuation) = AsyncStream<TimedBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.videoBufferDepth)
        )
        let (audioStream, audioContinuation) = AsyncStream<CMSampleBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(24)
        )
        self.videoContinuation = videoContinuation
        self.audioContinuation = audioContinuation

        super.init()

        videoConsumer = Task { [recordingService, performanceMonitor] in
            var sinceFlush = 0
            for await timed in videoStream {
                #if DEBUG
                // 3. the consumer received it.
                let receivedAt = Date()
                #endif
                #if DEBUG
                // 4. immediately before the actor call.
                let beforeAppend = Date()
                await recordingService.appendVideoSampleBuffer(timed.buffer, enqueuedAt: beforeAppend)
                // The consumer's reference to `timed` goes away at the end of this
                // iteration, returning the pixel buffer to the capture pool.
                self.recordDelivery(
                    capturedAt: timed.capturedAt,
                    yieldedAt: timed.yieldedAt,
                    receivedAt: receivedAt,
                    beforeAppend: beforeAppend,
                    sequence: timed.sequence
                )
                #else
                await recordingService.appendVideoSampleBuffer(timed.buffer)
                #endif
                // Task 067: the consumer is done with this buffer. Paired with the
                // increment on the capture queue, the difference is the live backlog.
                self.inFlightVideoBuffers.wrappingSubtract(1, ordering: .relaxed)
                sinceFlush += 1
                if sinceFlush >= Self.flushInterval {
                    await performanceMonitor.framesProcessed(sinceFlush)
                    sinceFlush = 0
                }
            }
        }

        audioConsumer = Task { [recordingService] in
            for await sampleBuffer in audioStream {
                await recordingService.appendAudioSampleBuffer(sampleBuffer)
            }
        }
    }

    deinit {
        videoContinuation.finish()
        audioContinuation.finish()
        videoConsumer?.cancel()
        audioConsumer?.cancel()
    }

    #if DEBUG
    /// Task 054 stages 2->3->4, accumulated on the consumer only.
    private func recordDelivery(capturedAt: Date, yieldedAt: Date, receivedAt: Date, beforeAppend: Date, sequence: Int) {
        deliveryCount += 1
        // Item 2: derived from values that both belong to this frame, so it can never
        // go negative. `sequence` counts frames handed to the stream, `deliveryCount`
        // counts frames drained; the difference is what is in flight or was dropped by
        // the stream between them.
        let inFlight = sequence - deliveryCount
        consumerInFlightMax = max(consumerInFlightMax, inFlight)
        let streamLatency = receivedAt.timeIntervalSince(yieldedAt)
        let preAppend = beforeAppend.timeIntervalSince(receivedAt)
        let endToEnd = beforeAppend.timeIntervalSince(capturedAt)
        streamLatencyTotal += streamLatency
        streamLatencyMax = max(streamLatencyMax, streamLatency)
        preAppendTotal += preAppend
        endToEndTotal += endToEnd
        endToEndMax = max(endToEndMax, endToEnd)

        let lifetime = Date().timeIntervalSince(capturedAt)
        lifetimeTotal += lifetime
        lifetimeMax = max(lifetimeMax, lifetime)
        if lifetime > 0.100 {
            slowBufferCount += 1
            slowBufferWorstMs = max(slowBufferWorstMs, lifetime * 1000)
        }

        guard deliveryCount % 120 == 0 else { return }
        let n = Double(deliveryCount)
        debugLog(String(
            format: "[Task054-Delivery] n=%d  yield->consumer avg=%.3fms max=%.3fms | consumer->append avg=%.3fms | captureEntry->append avg=%.3fms max=%.3fms",
            deliveryCount,
            streamLatencyTotal / n * 1000, streamLatencyMax * 1000,
            preAppendTotal / n * 1000,
            endToEndTotal / n * 1000, endToEndMax * 1000
        ))
        debugLog(String(
            format: "[Task055-Pool] bufferDepth=%d  inFlight=%d max=%d  bufferLifetime avg=%.3fms max=%.3fms  delivered=%d  slow(>100ms)=%d worst=%.1fms",
            Self.videoBufferDepth,
            inFlight, consumerInFlightMax,
            lifetimeTotal / n * 1000, lifetimeMax * 1000,
            deliveryCount,
            slowBufferCount, slowBufferWorstMs
        ))
    }
    #endif

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureVideoDataOutput {
            #if DEBUG
            // 1. delegate entry, and the gap since the previous one. If this interval
            // sits near 16.7ms the camera IS delivering 60fps and the loss is
            // downstream; if it sits near 22-25ms the camera itself is producing fewer
            // frames and nothing after this point can recover them.
            let entry = Date()
            if let last = lastCallbackEntry {
                let interval = entry.timeIntervalSince(last)
                intervalTotal += interval
                intervalMax = max(intervalMax, interval)
            }
            lastCallbackEntry = entry
            callbackCount += 1
            logConfigurationOnce(output: output)

            // 2. about to hand it over.
            let yieldAt = Date()
            yieldDelayTotal += yieldAt.timeIntervalSince(entry)
            logPoolOnce(sampleBuffer)
            videoYieldedTotal += 1
            let result = videoContinuation.yield(TimedBuffer(
                buffer: sampleBuffer,
                capturedAt: entry,
                yieldedAt: yieldAt,
                sequence: videoYieldedTotal
            ))
            if case .dropped = result {
                yieldDropped += 1
                // Task 057 item 3: recorded in every configuration so Release can be
                // judged; Debug keeps the local counter for the periodic line.
                let monitor = performanceMonitor
                Task { await monitor.recordDroppedBeforeConsumer() }
            }
            trackInFlight(result)

            let execution = Date().timeIntervalSince(entry)
            executionTotal += execution
            executionMax = max(executionMax, execution)

            if callbackCount % 120 == 0 {
                let n = Double(callbackCount - 1)
                let intervalAvg = n > 0 ? intervalTotal / n * 1000 : 0
                debugLog(String(
                    format: "[Task054-Capture] callbacks=%d  interval avg=%.3fms max=%.3fms (=> %.1ffps) | execution avg=%.3fms max=%.3fms | entry->yield avg=%.3fms | yieldDropped=%d lateDropped=%d",
                    callbackCount,
                    intervalAvg, intervalMax * 1000,
                    intervalAvg > 0 ? 1000 / intervalAvg : 0,
                    executionTotal / Double(callbackCount) * 1000, executionMax * 1000,
                    yieldDelayTotal / Double(callbackCount) * 1000,
                    yieldDropped, lateDropCount
                ))
            }
            #else
            let result = videoContinuation.yield(TimedBuffer(buffer: sampleBuffer))
            if case .dropped = result {
                let monitor = performanceMonitor
                Task { await monitor.recordDroppedBeforeConsumer() }
            }
            trackInFlight(result)
            #endif
        } else if output is AVCaptureAudioDataOutput {
            audioContinuation.yield(sampleBuffer)
        }
    }

    #if DEBUG
    /// Task 055 items 2/3: the capture pool a delivered buffer actually came from,
    /// with its attributes. `AVCaptureVideoDataOutput` does not expose its pool, but
    /// every buffer it hands over carries a reference to it, so this reads the real
    /// one rather than inferring it.
    private func logPoolOnce(_ sampleBuffer: CMSampleBuffer) {
        guard !didLogPool else { return }
        didLogPool = true
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            debugLog("[Task055-Pool] no CVImageBuffer on the sample buffer")
            return
        }
        // There is no public API to read AVCaptureVideoDataOutput's pool directly, so
        // the pool's *size* cannot be printed. What is observable is each buffer's
        // shape and whether it is IOSurface-backed (capture pools always are), plus —
        // the number that actually matters — how many of them this code is holding at
        // once, reported in the periodic [Task055-Pool] line below.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let hasIOSurface = CVPixelBufferGetIOSurface(pixelBuffer) != nil
        let formatString = String(bytes: [
            UInt8((format >> 24) & 0xFF), UInt8((format >> 16) & 0xFF),
            UInt8((format >> 8) & 0xFF), UInt8(format & 0xFF)
        ], encoding: .ascii) ?? "\(format)"
        debugLog("[Task055-Pool] captureBuffer=\(width)x\(height) pixelFormat=\(formatString) ioSurfaceBacked=\(hasIOSurface)")
    }

    /// The output's real configuration, printed once. `alwaysDiscardsLateVideoFrames`
    /// is the one that matters most here: it defaults to `true`, which tells
    /// AVFoundation to discard any frame that becomes available while the delegate is
    /// still executing the previous one — frames lost before this code ever sees them,
    /// and invisible to every timer downstream.
    private func logConfigurationOnce(output: AVCaptureOutput) {
        guard !didLogConfiguration else { return }
        didLogConfiguration = true
        guard let videoDataOutput = output as? AVCaptureVideoDataOutput else { return }
        debugLog("""
        [Task054-Config] alwaysDiscardsLateVideoFrames=\(videoDataOutput.alwaysDiscardsLateVideoFrames)
        [Task054-Config] sampleBufferCallbackQueue=\(callbackQueueLabel)
        [Task054-Config] videoSettings=\(videoDataOutput.videoSettings ?? [:])
        [Task054-Config] automaticallyConfiguresOutputBufferDimensions=\(videoDataOutput.automaticallyConfiguresOutputBufferDimensions) deliversPreviewSizedOutputBuffers=\(videoDataOutput.deliversPreviewSizedOutputBuffers)
        """)
    }
    #endif

    /// Task 067: `+1` only when the buffer actually entered the stream.
    ///
    /// `.dropped` is net zero either way its semantics are read. If it means the new
    /// element was rejected, nothing entered. If it means the oldest was evicted to make
    /// room (which is what `.bufferingNewest` does), then one entered and one left
    /// without ever reaching the consumer to be decremented. Both are `+0`.
    private func trackInFlight(_ result: AsyncStream<TimedBuffer>.Continuation.YieldResult) {
        if case .enqueued = result {
            inFlightVideoBuffers.wrappingAdd(1, ordering: .relaxed)
        }
    }

    /// Task 067: everything observable about one dropped frame.
    ///
    /// The three constants the task named — `…ReasonInfo_CaptureQueueDepth`,
    /// `_FrameNumber`, `_Timestamp` — **do not exist in CoreMedia.** The SDK declares
    /// exactly two dropped-frame attachment keys (`DroppedFrameReason`,
    /// `DroppedFrameReasonInfo`) and one ReasonInfo value (`_CameraModeSwitch`).
    ///
    /// So rather than probe for names that cannot resolve, this copies the buffer's
    /// entire attachment dictionary and prints whatever is actually on it. That is
    /// strictly more informative: it also catches any undocumented key AVFoundation
    /// attaches, which is what the named constants were reaching for.
    private func dropDetail(_ sampleBuffer: CMSampleBuffer, reason: String) -> (line: String, keys: [String]) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let attachments = CMCopyDictionaryOfAttachments(
            allocator: kCFAllocatorDefault,
            target: sampleBuffer,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        ) as? [String: Any] ?? [:]

        let keys = attachments.keys.sorted()
        let rendered = keys.isEmpty
            ? "(none)"
            : keys.map { "\($0)=\(attachments[$0].map { "\($0)" } ?? "nil")" }.joined(separator: " ")

        let line = """
        [Task067-Drop] reason=\(reason) \
        pts=\(pts.isValid ? String(format: "%.4fs", pts.seconds) : "invalid") \
        uptime=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \
        thermal=\(ProcessInfo.processInfo.thermalState.reportName) \
        backlog=\(inFlightVideoBuffers.load(ordering: .relaxed)) \
        attachments: \(rendered)
        """
        return (line, keys)
    }

    /// AVFoundation calls this instead of `didOutput` when it has to drop a sample —
    /// e.g. because the pipeline (recording write, in our case) couldn't keep up.
    /// Task 060 item 1: why AVFoundation discarded this frame, straight from the
    /// buffer's own attachment rather than inferred.
    ///
    /// The three reasons mean very different things:
    ///   FrameWasLate   - the delegate had not returned in time. Our delegate only
    ///                    yields, so this would point at the callback queue.
    ///   OutOfBuffers   - the capture pool had no free buffer. This is the one that
    ///                    implicates whoever is still holding them.
    ///   Discontinuity  - the capture itself was interrupted (thermal, resource loss).
    /// Recorded in every configuration, since the 38.7fps is a Release symptom.
    private nonisolated static func dropReason(of sampleBuffer: CMSampleBuffer) -> String {
        guard let reason = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil
        ) as? String else {
            return "Unknown"
        }
        if reason == (kCMSampleBufferDroppedFrameReason_FrameWasLate as String) { return "FrameWasLate" }
        if reason == (kCMSampleBufferDroppedFrameReason_OutOfBuffers as String) { return "OutOfBuffers" }
        if reason == (kCMSampleBufferDroppedFrameReason_Discontinuity as String) { return "Discontinuity" }
        return reason
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let performanceMonitor = performanceMonitor
        if output is AVCaptureVideoDataOutput {
            #if DEBUG
            lateDropCount += 1
            #endif
            let reason = Self.dropReason(of: sampleBuffer)
            Task { await performanceMonitor.recordDropReason(reason) }
            Task { await performanceMonitor.recordDroppedVideoFrame() }

            // Task 067: the full dump is bounded to the first few drops. At 4K60 drops
            // arrive tens of times a second, and copying an attachment dictionary on the
            // capture queue that often would slow the very callback whose lateness is
            // under investigation — the measurement would create the symptom.
            //
            // The budget lives on the monitor so `startMonitoring()` resets it for every
            // recording; claiming a slot is one atomic decrement, no `await`.
            let claimed = performanceMonitor.remainingDropSampleBudget
                .wrappingSubtract(1, ordering: .relaxed).oldValue > 0
            if claimed {
                let detail = dropDetail(sampleBuffer, reason: reason)
                Task { await performanceMonitor.recordDropDetail(detail.line, attachmentKeys: detail.keys) }
                #if DEBUG
                debugLog(detail.line)
                #endif
            } else {
                // Past the sample budget, still collect the *keys* — cheap relative to
                // rendering values, and the union across the whole recording is what
                // proves which attachments exist at all.
                let attachments = CMCopyDictionaryOfAttachments(
                    allocator: kCFAllocatorDefault,
                    target: sampleBuffer,
                    attachmentMode: kCMAttachmentMode_ShouldPropagate
                ) as? [String: Any] ?? [:]
                let keys = Array(attachments.keys)
                Task { await performanceMonitor.recordDropDetail(nil, attachmentKeys: keys) }
            }
        } else if output is AVCaptureAudioDataOutput {
            Task { await performanceMonitor.recordDroppedAudioBuffer() }
        }
    }
}
