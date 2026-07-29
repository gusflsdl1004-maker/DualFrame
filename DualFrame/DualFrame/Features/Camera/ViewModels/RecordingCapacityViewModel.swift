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

    /// Task 050 requirement 2: the HUD's human-readable form — "6시간 12분", "48분",
    /// "35초". A ticking `HH:MM:SS` is right for a countdown during recording, but the
    /// HUD answers "roughly how much can I shoot?", where seconds of precision on a
    /// six-hour figure are noise.
    var approximateRemainingText: String {
        guard let estimatedSecondsRemaining else { return "--" }
        let clamped = max(0, estimatedSecondsRemaining)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)시간 \(minutes)분" : "\(hours)시간"
        }
        if minutes > 0 {
            return "\(minutes)분"
        }
        return "\(clamped)초"
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
    /// whatever `outputMode`/`activeQuality`/`activeFPS` are passed in, a settings
    /// change (Task 042's Long만/Short만/Long+Short 저장 choice included) or actual
    /// disk consumption is reflected within one second, with no separate
    /// "did settings change" plumbing needed.
    func refresh(outputMode: RecordingOutputMode, activeQuality: RecordingQuality?, activeFPS: RecordingFPS?) {
        let snapshot = storageService.currentSnapshot()
        availableBytes = snapshot?.availableBytes

        guard let available = snapshot?.availableBytes else {
            estimatedSecondsRemaining = nil
            return
        }

        let bitrateBps = totalBitrateBps(outputMode: outputMode, activeQuality: activeQuality, activeFPS: activeFPS)
        guard bitrateBps > 0 else {
            estimatedSecondsRemaining = nil
            return
        }

        estimatedSecondsRemaining = Int((Double(available) * 8) / bitrateBps)
    }

    /// 듀얼 저장 고려 (Task 042 requirement 6): Long만 → Long bitrate only, 둘 다 →
    /// Long + Short summed. Both cases reflect what `RecordingService` actually
    /// writes to disk today — no under-reporting caveat needed since the
    /// short-only-in-name-only option was removed.
    private func totalBitrateBps(outputMode: RecordingOutputMode, activeQuality: RecordingQuality?, activeFPS: RecordingFPS?) -> Double {
        switch outputMode {
        case .longOnly:
            guard let activeQuality, let activeFPS else { return 0 }
            let dimensions = activeQuality.dimensions
            return bitrateService.estimatedWriterBitrateBps(width: dimensions.width, height: dimensions.height, fps: activeFPS)

        case .both:
            // Task 046: the long-form writer follows the user's actual quality/FPS
            // (see `RecordingService.effectiveWriterFormat(for:)`), so this must too —
            // it previously used `OutputProfile.longForm`'s hardcoded 1080p30
            // constant and therefore under-reported a 4K/60 recording's disk usage by
            // roughly 8x, making "예상 촬영 가능" wildly optimistic.
            guard let activeQuality, let activeFPS else { return 0 }
            let dimensions = activeQuality.dimensions
            let longBitrate = bitrateService.estimatedWriterBitrateBps(
                width: dimensions.width,
                height: dimensions.height,
                fps: activeFPS
            )
            // Short-form keeps its fixed vertical delivery size but shares the
            // session's frame rate, matching `effectiveWriterFormat(for:)`.
            let shortBitrate = bitrateService.estimatedWriterBitrateBps(
                width: OutputProfile.shortForm.resolution.width,
                height: OutputProfile.shortForm.resolution.height,
                fps: activeFPS
            )
            return longBitrate + shortBitrate
        }
    }
}
