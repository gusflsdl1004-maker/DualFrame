//
//  RecordingCapacityViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Task 041: live storage + estimated-recording-time display. Read-only and fully
/// decoupled from the recording pipeline — never reads from or writes to
/// `RecordingService`/`CameraService`, only queries device storage and combines it
/// with an estimated bitrate for whatever resolution/FPS/mode the caller passes in.
@MainActor
final class RecordingCapacityViewModel: ObservableObject {
    enum WarningLevel {
        case normal
        case low
        case critical
    }

    @Published private(set) var availableBytes: Int64?
    @Published private(set) var estimatedSecondsRemaining: Int?

    private let storageService: StorageEstimationService
    private let bitrateService: BitrateEstimationService

    var formattedAvailableSpace: String {
        guard let availableBytes else { return "--" }
        return ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
    }

    var formattedEstimatedTime: String {
        guard let estimatedSecondsRemaining else { return "--:--:--" }
        let clamped = max(0, estimatedSecondsRemaining)
        return String(format: "%02d:%02d:%02d", clamped / 3600, (clamped % 3600) / 60, clamped % 60)
    }

    /// Requirement 4: 5분 이하 → 노란색, 1분 이하 → 빨간색.
    var warningLevel: WarningLevel {
        guard let estimatedSecondsRemaining else { return .normal }
        if estimatedSecondsRemaining <= 60 { return .critical }
        if estimatedSecondsRemaining <= 300 { return .low }
        return .normal
    }

    /// Requirement 5: storage is low enough that starting a recording would fail.
    var isStorageInsufficientToRecord: Bool {
        guard let estimatedSecondsRemaining else { return false }
        return estimatedSecondsRemaining <= 0
    }

    init(
        storageService: StorageEstimationService = StorageEstimationService(),
        bitrateService: BitrateEstimationService = BitrateEstimationService()
    ) {
        self.storageService = storageService
        self.bitrateService = bitrateService
    }

    /// Requirement 3/6: called once a second by the caller's own polling loop (idle
    /// or recording) — since this always re-reads live free space and recomputes from
    /// whatever `recordingMode`/`activeQuality`/`activeFPS` are passed in, a settings
    /// change or actual disk consumption is reflected within one second, with no
    /// separate "did settings change" plumbing needed.
    func refresh(recordingMode: RecordingMode, activeQuality: RecordingQuality?, activeFPS: RecordingFPS?) {
        let snapshot = storageService.currentSnapshot()
        availableBytes = snapshot?.availableBytes

        guard let available = snapshot?.availableBytes else {
            estimatedSecondsRemaining = nil
            return
        }

        let bitrateBps = totalBitrateBps(recordingMode: recordingMode, activeQuality: activeQuality, activeFPS: activeFPS)
        guard bitrateBps > 0 else {
            estimatedSecondsRemaining = nil
            return
        }

        estimatedSecondsRemaining = Int((Double(available) * 8) / bitrateBps)
    }

    /// 듀얼 저장 고려: sums each active writer's estimated bitrate. `.dual` mode's two
    /// writers use `OutputProfile.longForm`/`.shortForm`'s fixed dimensions — not the
    /// user's quality/FPS preference — matching `RecordingService.targetProfiles`'s
    /// actual `.dual` behavior (`.single`'s ad-hoc profile is the only one that honors
    /// `activeQuality`/`activeFPS`; `.dual` doesn't yet, per rule 43's
    /// architecture-only status).
    private func totalBitrateBps(recordingMode: RecordingMode, activeQuality: RecordingQuality?, activeFPS: RecordingFPS?) -> Double {
        switch recordingMode {
        case .single:
            guard let activeQuality, let activeFPS else { return 0 }
            let dimensions = activeQuality.dimensions
            return bitrateService.estimatedWriterBitrateBps(width: dimensions.width, height: dimensions.height, fps: activeFPS)

        case .dual:
            let longBitrate = bitrateService.estimatedWriterBitrateBps(
                width: OutputProfile.longForm.resolution.width,
                height: OutputProfile.longForm.resolution.height,
                fps: OutputProfile.longForm.fps
            )
            let shortBitrate = bitrateService.estimatedWriterBitrateBps(
                width: OutputProfile.shortForm.resolution.width,
                height: OutputProfile.shortForm.resolution.height,
                fps: OutputProfile.shortForm.fps
            )
            return longBitrate + shortBitrate
        }
    }
}
