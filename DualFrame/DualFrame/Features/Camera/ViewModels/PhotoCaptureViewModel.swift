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

    private let cameraService: CameraService
    private let photoLibraryService: InternalPhotoLibraryService
    private let photosExportService: PhotoLibraryExportService
    private let storageSettingsService: StorageSettingsService
    private let photoQualityService: PhotoQualitySettingsService
    private var countdownTask: Task<Void, Never>?

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
        guard !isCapturing, countdownTask == nil else { return }
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
        isCapturing = false
        isFlashingShutter = false
        errorMessage = nil
    }

    // MARK: - Private

    private func performCapture() async {
        // Task 092 P0-2/P0-4: **the only place these are cleared, and it always runs.**
        //
        // `defer` on the enclosing async function fires on every exit — normal return,
        // thrown error, and cancellation. Previously the white flash cleared itself from a
        // detached 90ms Task, which meant its lifetime was independent of the capture's:
        // if the capture path died, the overlay's fate was unrelated to the failure. Now
        // the overlay is owned by the operation that raised it and cannot outlive it.
        defer {
            isCapturing = false
            isFlashingShutter = false
        }
        errorMessage = nil

        // Fires before the await so it lands with the shutter action rather than after the
        // encode. This is the feedback that tells the user the moment was taken.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isFlashingShutter = true

        do {
            // Task 092 P1-1: **screen flash on the front camera.**
            //
            // The front camera has no lamp — `supportedFlashModes` is `[.off]` there, so
            // `flashMode` is silently ignored no matter what the control says. Holding the
            // white overlay up *through* the exposure is what the system Camera does, and
            // it is a real light source: the screen is what illuminates the subject.
            //
            // Only when flash is actually asked for. On `.off`, or on a camera with a
            // lamp, the overlay stays the brief shutter blink it was.
            let hasLamp = await cameraService.hasHardwareFlash
            let usesScreenFlash = flashMode != .off && !hasLamp
            if usesScreenFlash {
                // Long enough for the exposure to be taken under it. Cleared by the
                // `defer` above regardless of what happens next.
                try? await Task.sleep(for: .milliseconds(220))
            }

            let captured = try await captureWithTimeout()
            let position = await cameraService.currentPosition
            let record = try await photoLibraryService.save(
                data: captured.data,
                capturedAt: Date(),
                cameraPosition: position,
                fileExtension: captured.fileExtension
            )
            lastCapturedRecord = record
            await exportIfSettingsAskFor(record)
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
    private func captureWithTimeout() async throws -> (data: Data, fileExtension: String) {
        try await withThrowingTaskGroup(of: (data: Data, fileExtension: String).self) { group in
            let mode = flashMode.avFlashMode
            // Task 093 P1-6: read fresh on every capture, so a change made in settings
            // applies to the very next photo without an app restart.
            let quality = photoQualityService.load().quality
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
    private func exportIfSettingsAskFor(_ record: PhotoRecord) async {
        let settings = storageSettingsService.load()
        guard settings.defaultDestination == .photos else {
            statusMessage = "사진이 보관함에 저장되었습니다."
            return
        }

        do {
            try await photosExportService.exportPhoto(at: record.localURL)
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
