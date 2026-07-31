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
    private var countdownTask: Task<Void, Never>?

    init(
        cameraService: CameraService,
        photoLibraryService: InternalPhotoLibraryService,
        photosExportService: PhotoLibraryExportService = PhotoLibraryExportService(),
        storageSettingsService: StorageSettingsService = StorageSettingsService()
    ) {
        self.cameraService = cameraService
        self.photoLibraryService = photoLibraryService
        self.photosExportService = photosExportService
        self.storageSettingsService = storageSettingsService
    }

    /// The shutter. Runs the self-timer first when one is set.
    func capture() {
        guard !isCapturing, countdownTask == nil else { return }

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
    }

    // MARK: - Private

    private func performCapture() async {
        isCapturing = true
        defer { isCapturing = false }
        errorMessage = nil

        // Fires before the await so it lands with the shutter sound rather than after the
        // encode. This is the feedback that tells the user the moment was taken.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashShutter()

        do {
            let captured = try await cameraService.capturePhoto(flashMode: flashMode.avFlashMode)
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
        } catch {
            errorMessage = "사진을 저장하지 못했습니다."
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

    private func flashShutter() {
        isFlashingShutter = true
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            isFlashingShutter = false
        }
    }
}

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
