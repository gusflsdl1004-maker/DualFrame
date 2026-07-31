//
//  PhotoCaptureViewModel.swift
//  DualFrame
//

import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Task 091: drives photo mode — the shutter, the countdown, and where the result goes.
///
/// Deliberately separate from `RecordingViewModel`. Photo capture and video recording
/// share the session and nothing else, and the recording view model is the most
/// safety-critical object in the app; a still that fails to save must not be able to
/// reach any of its state. The only thing they share is the rule that they never run at
/// once, which `CameraService.capturePhoto` enforces on its own side too.
@MainActor
final class PhotoCaptureViewModel: ObservableObject {
    /// Set for a moment after the shutter fires, so the view can flash the screen white.
    @Published private(set) var isFlashingShutter = false
    @Published private(set) var isCapturing = false
    /// Seconds left on the self-timer, or nil when it is not running.
    @Published private(set) var countdown: Int?
    @Published var flashMode: PhotoFlashMode = .auto
    @Published var timerDuration: PhotoTimerDuration = .off
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    /// The most recent still, so the gallery can refresh without polling.
    @Published private(set) var lastCapturedRecord: PhotoRecord?
    /// Task 096 P0-1: shutter taps taken while an exposure is already running.
    ///
    /// Taps used to be discarded — the button was `.disabled` during the exposure, so the
    /// tap was never even delivered, and the view-model guard dropped whatever got
    /// through. That is what "셔터가 반응하지 않는다" was: not a slow shutter, a *deaf* one.
    @Published private(set) var queuedCaptures = 0
    /// Task 096 P0-3: photos taken but not yet written. Shown in the UI, because a user
    /// who has just fired ten shots needs to see that ten are accounted for — "trust me,
    /// it is saving in the background" is not something an app should ask for.
    @Published private(set) var pendingSaveCount = 0

    private let cameraService: CameraService
    private let photoLibraryService: InternalPhotoLibraryService
    private let photosExportService: PhotoLibraryExportService
    private let storageSettingsService: StorageSettingsService
    private let photoQualityService: PhotoQualitySettingsService
    private var countdownTask: Task<Void, Never>?
    /// Task 095: ends the shutter flash on its own short schedule, independent of how long
    /// the capture and save take.
    private var flashClearTask: Task<Void, Never>?
    /// Deep enough that a burst of taps all land, shallow enough that a thumb resting on
    /// the shutter cannot queue an unbounded number of exposures.
    private static let maxQueuedCaptures = 8

    init(
        cameraService: CameraService,
        photoLibraryService: InternalPhotoLibraryService,
        photosExportService: PhotoLibraryExportService = PhotoLibraryExportService(),
        storageSettingsService: StorageSettingsService = StorageSettingsService(),
        photoQualityService: PhotoQualitySettingsService = PhotoQualitySettingsService()
    ) {
        self.cameraService = cameraService
        self.photoLibraryService = photoLibraryService
        self.photosExportService = photosExportService
        self.storageSettingsService = storageSettingsService
        self.photoQualityService = photoQualityService
    }

    /// The shutter. Runs the self-timer first when one is set.
    ///
    /// Task 092 P1-3: `isCapturing` is set **here**, synchronously, before any `await`
    /// exists to suspend at. Setting it inside the async body left a window where two
    /// taps in the same run loop turn could both pass the guard and both reach
    /// `capturePhoto`. On `@MainActor` this method runs to completion before another tap
    /// can be delivered, so the guard is now airtight rather than probabilistic.
    func capture() {
        // Task 096 P0-1/P0-4: a tap during an exposure is remembered, not dropped, and it
        // gets its own haptic immediately so the button never feels dead. Bounded, because
        // an unbounded queue turns a leaning thumb into a hundred photos.
        guard countdownTask == nil else { return }
        if isCapturing {
            guard queuedCaptures < Self.maxQueuedCaptures else { return }
            queuedCaptures += 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        isCapturing = true

        guard timerDuration != .off else {
            Task { await performCapture() }
            return
        }

        countdownTask = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: timerDuration.seconds, through: 1, by: -1) {
                self.countdown = remaining
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
            }
            self.countdown = nil
            self.countdownTask = nil
            guard !Task.isCancelled else { return }
            await self.performCapture()
        }
    }

    /// Cancels a running self-timer. Tapping the shutter again during a countdown should
    /// stop it, not queue a second photo.
    func cancelTimer() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        // Task 092 P1-3: `capture()` claims `isCapturing` before the countdown starts, so
        // cancelling has to release it or the shutter stays dead for the rest of the run.
        isCapturing = false
    }

    /// Task 092 P0-3: called when the camera screen appears. Clears anything a previous
    /// capture could have left behind.
    ///
    /// Nothing here is persisted — `CaptureMode` is view state and these are view-model
    /// properties, so a relaunch already starts clean. This exists for the case a
    /// relaunch does *not* cover: returning to the camera from the gallery or settings
    /// while a capture was in flight. Cheap, and it makes "the UI is stuck" unreachable
    /// by one more route.
    func resetTransientState() {
        cancelTimer()
        flashClearTask?.cancel()
        isCapturing = false
        isFlashingShutter = false
        errorMessage = nil
    }

    // MARK: - Private

    private func performCapture() async {
        // Task 095 P0-1: **this `defer` is the safety net, not the timing.**
        //
        // Task 092 tied the flash's lifetime to the whole capture operation so it could
        // never be stranded. That fixed the strand and created this bug: "the whole
        // operation" is the exposure, *plus* writing several megabytes to disk, *plus* a
        // full `PHPhotoLibrary.performChanges` round trip when Photos saving is on. One to
        // two seconds of white screen, exactly as reported. Correct lifetime, wrong
        // duration.
        //
        // The flash now has both properties instead of one: `flashClearTask` ends it in
        // ~80ms on the normal path, and this still force-clears it on every exit —
        // return, throw, cancellation — so it cannot outlive the operation either.
        defer {
            flashClearTask?.cancel()
            isFlashingShutter = false
            // Task 096 P0-1: hand straight on to the next queued shot rather than idling.
            // Still inside `defer`, so a thrown capture drains the queue too — otherwise
            // one failure would strand every tap behind it.
            if queuedCaptures > 0 {
                queuedCaptures -= 1
                Task { await performCapture() }
            } else {
                isCapturing = false
            }
        }
        errorMessage = nil

        // Fires before the await so it lands with the shutter action rather than after the
        // encode. This is the feedback that tells the user the moment was taken.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        do {
            // Task 092 P1-1 / 095 P0-3: **screen flash is a light source; the blink is not.**
            //
            // The front camera has no lamp — `supportedFlashModes` is `[.off]` there, so
            // `flashMode` is silently ignored no matter what the control says. Holding the
            // white overlay up *through* the exposure is what the system Camera does, and
            // it really is what illuminates the subject, so that one has to last as long
            // as the exposure.
            //
            // Every other case gets a blink measured in milliseconds, because there the
            // white screen is decoration and decoration must not cover the viewfinder.
            let hasLamp = await cameraService.hasHardwareFlash
            let usesScreenFlash = flashMode != .off && !hasLamp
            beginShutterFlash(holdingForExposure: usesScreenFlash)

            // Task 093 P1-6 / 094: read once here, so the photo is captured, saved and
            // labelled with the same value even if the setting changes mid-capture.
            let quality = photoQualityService.load().quality
            let captured = try await captureWithTimeout(quality: quality)
            let position = await cameraService.currentPosition

            // Task 095 P0-2: **the shutter is free the moment the sensor is done.**
            //
            // Writing the file and copying it to Photos are not part of taking the photo —
            // they are what happens to it afterwards, and making the user wait through them
            // is what made rapid shooting impossible. Handed to a detached task; this
            // function returns, `defer` releases the shutter, and the preview is live again.
            persistInBackground(captured, position: position, quality: quality)
        } catch CameraServiceError.photoCaptureWhileRecording {
            errorMessage = "녹화 중에는 사진을 촬영할 수 없습니다."
        } catch CameraServiceError.photoOutputUnavailable {
            errorMessage = "이 기기 설정에서는 사진 촬영을 사용할 수 없습니다."
        } catch is PhotoCaptureTimeout {
            errorMessage = "사진 촬영이 응답하지 않아 취소했습니다. 다시 시도해 주세요."
        } catch {
            errorMessage = "사진을 저장하지 못했습니다."
        }
    }

    /// Task 092 P0-2: a capture that never comes back must not hold the UI forever.
    ///
    /// `AVCapturePhotoOutput` delivers its result through a delegate. If that callback
    /// never arrives — the session is interrupted mid-capture, the delegate is dropped —
    /// the continuation never resumes and the `await` above never returns, so the `defer`
    /// that clears the white flash never runs either. A stuck camera would look exactly
    /// like the crash this task is fixing.
    ///
    /// Eight seconds is far longer than any real still (well under a second even at 4K
    /// with flash), so this can only fire on a genuine hang.
    private func captureWithTimeout(quality: PhotoQuality) async throws -> (data: Data, fileExtension: String) {
        try await withThrowingTaskGroup(of: (data: Data, fileExtension: String).self) { group in
            let mode = flashMode.avFlashMode
            group.addTask { [cameraService] in
                try await cameraService.capturePhoto(flashMode: mode, quality: quality)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw PhotoCaptureTimeout()
            }
            guard let first = try await group.next() else { throw PhotoCaptureTimeout() }
            // Cancels the loser — either the sleep, or a capture nobody is waiting for.
            group.cancelAll()
            return first
        }
    }

    /// The internal copy is already written by the time this runs, so a Photos failure
    /// costs the user a message rather than the photo — the same ordering the video
    /// export path uses.
    /// Task 095 P0-1/P0-3: raises the flash and schedules its own end.
    ///
    /// 80ms is roughly five frames at 60Hz — long enough to register as a blink, short
    /// enough that it is gone before the eye settles on it. `holdingForExposure` is the
    /// front-camera case, where the white screen is doing real work and has to stay up
    /// while the sensor is exposing.
    private func beginShutterFlash(holdingForExposure: Bool) {
        flashClearTask?.cancel()
        isFlashingShutter = true
        let duration: Duration = holdingForExposure ? .milliseconds(220) : .milliseconds(80)
        flashClearTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.isFlashingShutter = false
        }
    }

    /// Task 095 P0-2: disk write and Photos export, off the shutter's critical path.
    ///
    /// Detached from the capture so the next photo can be taken immediately. Errors still
    /// surface — published the same way, just later — because a save that failed silently
    /// would be worse than a slow one.
    ///
    /// Nothing cancels this. Once the sensor has produced an image, that image gets
    /// written; tying it to a task the UI can cancel would mean a photo the user watched
    /// being taken could vanish, which is the one outcome this app does not allow
    /// (CLAUDE.md rule 1).
    private func persistInBackground(
        _ captured: (data: Data, fileExtension: String),
        position: CameraPosition,
        quality: PhotoQuality
    ) {
        let photoLibraryService = self.photoLibraryService
        pendingSaveCount += 1
        Task { [weak self] in
            defer { self?.pendingSaveCount -= 1 }
            do {
                let record = try await photoLibraryService.save(
                    data: captured.data,
                    capturedAt: Date(),
                    cameraPosition: position,
                    fileExtension: captured.fileExtension,
                    quality: quality
                )
                guard let self else { return }
                self.lastCapturedRecord = record
                await self.exportIfSettingsAskFor(record)
            } catch {
                self?.errorMessage = "사진을 저장하지 못했습니다."
            }
        }
    }

    private func exportIfSettingsAskFor(_ record: PhotoRecord) async {
        let settings = storageSettingsService.load()
        guard settings.defaultDestination == .photos else {
            statusMessage = "사진이 보관함에 저장되었습니다."
            return
        }

        do {
            try await photosExportService.exportPhoto(at: record.localURL)
            // Task 094: so the debug panel can state where this photo actually lives.
            await photoLibraryService.markSavedToPhotos(record)
            statusMessage = "사진 앱에 저장되었습니다."
        } catch {
            statusMessage = "보관함에 저장했지만 사진 앱 저장은 실패했습니다."
        }
    }

}

/// Task 092: raised when the photo delegate never calls back. A distinct type so the
/// message can say "it hung" rather than "it failed", which are different problems.
nonisolated struct PhotoCaptureTimeout: Error {}

/// Task 091 P2-1.
nonisolated enum PhotoFlashMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case on
    case off

    var id: String { rawValue }

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: .auto
        case .on: .on
        case .off: .off
        }
    }

    var symbolName: String {
        switch self {
        case .auto: "bolt.badge.a.fill"
        case .on: "bolt.fill"
        case .off: "bolt.slash.fill"
        }
    }

    var next: PhotoFlashMode {
        switch self {
        case .auto: .on
        case .on: .off
        case .off: .auto
        }
    }
}

/// Task 091 P2-2.
nonisolated enum PhotoTimerDuration: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case three = 3
    case ten = 10

    var id: Int { rawValue }
    var seconds: Int { rawValue }

    var symbolName: String {
        switch self {
        case .off: "timer"
        case .three: "timer"
        case .ten: "timer"
        }
    }

    var label: String {
        switch self {
        case .off: "OFF"
        case .three: "3s"
        case .ten: "10s"
        }
    }

    var next: PhotoTimerDuration {
        switch self {
        case .off: .three
        case .three: .ten
        case .ten: .off
        }
    }
}
