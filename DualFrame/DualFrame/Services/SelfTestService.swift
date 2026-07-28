//
//  SelfTestService.swift
//  DualFrame
//

#if DEBUG
import AVFoundation
import Photos

/// Automated Self Test (Task 030) — a debug-only, read-only sweep of the core
/// components a recording depends on, run at app launch so a physical device's basic
/// health can be checked at a glance. Entire file wrapped in `#if DEBUG`: none of it,
/// including this type, is compiled into a Release build.
///
/// Hard requirements: never starts a real recording, never changes any setting. Every
/// check either reads an already-existing service/permission API, or (for the writer
/// feasibility check) builds a throwaway `AVAssetWriter` against a temp file that is
/// completely independent of `RecordingService`'s real writer — deleted immediately
/// after, it never touches anything the real recording pipeline uses.
actor SelfTestService {
    func run(libraryService: InternalVideoLibraryService, externalStorageViewModel: ExternalStorageViewModel) async -> [SelfTestItem] {
        var items: [SelfTestItem] = []

        items.append(cameraPermissionItem())
        items.append(microphonePermissionItem())
        items.append(await internalLibraryItem(libraryService: libraryService))
        items.append(photosPermissionItem())
        items.append(await externalStorageItem(externalStorageViewModel: externalStorageViewModel))

        let positionSettings = CameraPositionSettingsService().load()
        let modeSettings = RecordingModeSettingsService().load()
        let qualitySettings = RecordingQualitySettingsService().load()
        let fpsSettings = RecordingFPSSettingsService().load()

        items.append(SelfTestItem(id: "settings", title: "Recording Settings Load", status: .pass, detail: nil))
        items.append(SelfTestItem(id: "position", title: "Camera Position", status: .pass, detail: positionSettings.selectedPosition.title))
        items.append(SelfTestItem(id: "mode", title: "Recording Mode", status: .pass, detail: modeSettings.mode.title))
        items.append(SelfTestItem(
            id: "resolution",
            title: "Resolution",
            status: .pass,
            detail: "\(qualitySettings.selectedQuality.dimensions.width)×\(qualitySettings.selectedQuality.dimensions.height)"
        ))
        items.append(SelfTestItem(id: "fps", title: "FPS", status: .pass, detail: fpsSettings.selectedFPS.title))

        items.append(writerCreationItem())

        return items
    }

    private func cameraPermissionItem() -> SelfTestItem {
        SelfTestItem(id: "camera-permission", title: "Camera Permission", status: mapAVStatus(AVCaptureDevice.authorizationStatus(for: .video)), detail: nil)
    }

    private func microphonePermissionItem() -> SelfTestItem {
        SelfTestItem(id: "mic-permission", title: "Microphone Permission", status: mapAVStatus(AVCaptureDevice.authorizationStatus(for: .audio)), detail: nil)
    }

    private func mapAVStatus(_ status: AVAuthorizationStatus) -> SelfTestStatus {
        switch status {
        case .authorized: .pass
        case .notDetermined: .warning("Not determined yet")
        case .denied, .restricted: .fail("Denied")
        @unknown default: .warning("Unknown status")
        }
    }

    private func internalLibraryItem(libraryService: InternalVideoLibraryService) async -> SelfTestItem {
        do {
            _ = try await libraryService.loadAllRecords()
            return SelfTestItem(id: "library", title: "Internal Library Access", status: .pass, detail: nil)
        } catch {
            return SelfTestItem(id: "library", title: "Internal Library Access", status: .fail("Could not read library"), detail: nil)
        }
    }

    private func photosPermissionItem() -> SelfTestItem {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let mapped: SelfTestStatus
        switch status {
        case .authorized, .limited: mapped = .pass
        case .notDetermined: mapped = .warning("Not determined yet")
        case .denied, .restricted: mapped = .fail("Denied")
        @unknown default: mapped = .warning("Unknown status")
        }
        return SelfTestItem(id: "photos-permission", title: "Photos Permission", status: mapped, detail: nil)
    }

    @MainActor
    private func externalStorageItem(externalStorageViewModel: ExternalStorageViewModel) -> SelfTestItem {
        switch externalStorageViewModel.status {
        case .connected:
            return SelfTestItem(id: "external-storage", title: "External Storage", status: .pass, detail: externalStorageViewModel.device?.name)
        case .disconnected:
            return SelfTestItem(id: "external-storage", title: "External Storage", status: .warning("Not connected"), detail: nil)
        case .unavailable:
            return SelfTestItem(id: "external-storage", title: "External Storage", status: .fail("Unavailable"), detail: externalStorageViewModel.errorMessage)
        }
    }

    /// Requirement: never starts a real recording. This builds a throwaway
    /// `AVAssetWriter` against a temp file purely to check that writer creation is
    /// currently feasible on this device — nothing here is the real `RecordingService`
    /// writer, and the temp file is removed immediately after the check.
    private func writerCreationItem() -> SelfTestItem {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_selftest.mov")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let writer = try AVAssetWriter(url: url, fileType: .mov)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            guard writer.canAdd(videoInput) else {
                return SelfTestItem(id: "writer", title: "Writer Creation Feasibility", status: .fail("Cannot add video input"), detail: nil)
            }
            writer.add(videoInput)

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            guard writer.canAdd(audioInput) else {
                return SelfTestItem(id: "writer", title: "Writer Creation Feasibility", status: .fail("Cannot add audio input"), detail: nil)
            }
            writer.add(audioInput)

            return SelfTestItem(id: "writer", title: "Writer Creation Feasibility", status: .pass, detail: nil)
        } catch {
            return SelfTestItem(id: "writer", title: "Writer Creation Feasibility", status: .fail(error.localizedDescription), detail: nil)
        }
    }
}
#endif
