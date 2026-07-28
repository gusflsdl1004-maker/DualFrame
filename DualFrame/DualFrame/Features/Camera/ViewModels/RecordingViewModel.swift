//
//  RecordingViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Exposes recording state and validation results to the camera screen, and drives
/// the start/stop flow. Owns no capture/writing logic itself — that lives in
/// `RecordingService`.
@MainActor
final class RecordingViewModel: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastValidationResult: RecordingValidationResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var performanceSnapshot: RecordingPerformanceSnapshot?
    @Published private(set) var lowStorageWarning: String?
    @Published private(set) var interruptionStatus: InterruptionStatus = .none

    var statusText: String {
        switch state {
        case .idle: "READY"
        case .preparing: "PREPARING"
        case .recording: "RECORDING"
        case .stopping: "STOPPING"
        case .finished: "SUCCESS"
        case .failed: "FAILED"
        }
    }

    var formattedDuration: String { Self.format(seconds: duration) }

    var formattedFileSize: String {
        guard let bytes = lastValidationResult?.fileSize else { return "--" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var formattedRecordedDuration: String {
        guard let seconds = lastValidationResult?.duration else { return "--" }
        return Self.format(seconds: seconds)
    }

    var formattedResolution: String {
        guard let size = lastValidationResult?.resolution else { return "--" }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    var isRecording: Bool { state == .recording }

    var formattedDroppedFrames: String {
        guard let snapshot = performanceSnapshot else { return "0" }
        return "\(snapshot.droppedVideoFrames + snapshot.droppedAudioBuffers)"
    }

    var memoryStatusText: String {
        guard let snapshot = performanceSnapshot else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(snapshot.memoryUsageBytes), countStyle: .memory)
    }

    var writeStatusText: String {
        guard let snapshot = performanceSnapshot else { return "--" }
        return snapshot.averageWriteLatency > 0.05 ? "Slow" : "Normal"
    }

    private let service: RecordingService
    private let diagnosticsService: RecordingDiagnosticsService
    private var durationTask: Task<Void, Never>?
    private var interruptionOccurredThisSession = false

    init(service: RecordingService, diagnosticsService: RecordingDiagnosticsService = RecordingDiagnosticsService()) {
        self.service = service
        self.diagnosticsService = diagnosticsService
    }

    /// Toggles between starting and stopping — the single button the camera screen exposes.
    /// `expectsAudioTrack` should reflect whether microphone permission was granted.
    func toggleRecording(expectsAudioTrack: Bool) {
        Task {
            if isRecording {
                await stopRecording(expectsAudioTrack: expectsAudioTrack)
            } else {
                await startRecording()
            }
        }
    }

    func startRecording() async {
        lastValidationResult = nil
        errorMessage = nil

        if state != .preparing {
            state = await service.prepareRecording()
            lowStorageWarning = await service.performanceMonitor.lowStorageWarning
        }
        guard state == .preparing else {
            errorMessage = await service.lastError?.message
            return
        }
        state = await service.startRecording()
        if state == .recording {
            performanceSnapshot = nil
            interruptionOccurredThisSession = false
            startDurationTimer()
        }
    }

    func stopRecording(expectsAudioTrack: Bool) async {
        guard state == .recording else { return }
        let startTime = await service.recordingStartTime ?? Date()

        state = await service.stopRecording(expectsAudioTrack: expectsAudioTrack)
        stopDurationTimer()
        lastValidationResult = await service.lastValidationResult

        await recordDiagnostics(startTime: startTime, endTime: Date())

        if state == .finished {
            lastRecordingURL = await service.outputFileURL()
        } else {
            errorMessage = await service.lastError?.message
        }
    }

    /// Called by `RecordingInterruptionMonitor` when an interruption begins. Pauses the
    /// recording (if one is active) and preserves a checkpoint — never resumes anything.
    func handleInterruptionBegan(_ source: InterruptionSource) async {
        interruptionStatus = .interrupted(source)
        interruptionOccurredThisSession = true
        await service.pauseRecording()
    }

    /// Called when the interruption ends. Only updates the displayed status — recording
    /// stays paused; nothing here calls `resumeRecording()` (requirement 8, 11).
    func handleInterruptionEnded() {
        guard interruptionStatus != .none else { return }
        interruptionStatus = .ended
    }

    /// Builds and saves a `RecordingDiagnostics` record for the session that just
    /// ended (success or failure) — one file per session (Task 018 requirement 5).
    private func recordDiagnostics(startTime: Date, endTime: Date) async {
        let snapshot = await service.performanceMonitor.snapshot
        let peakMemory = await service.performanceMonitor.peakMemoryUsageBytes
        let availableStorage = await service.performanceMonitor.currentAvailableStorageBytes() ?? 0
        let checkpointCount = await service.checkpointSaveCount
        let resolution = await service.activeQuality
        let fps = await service.activeFPS

        let recoveryStatus: DiagnosticsRecoveryStatus
        if state == .finished {
            recoveryStatus = interruptionOccurredThisSession ? .completedAfterInterruption : .completedNormally
        } else {
            recoveryStatus = .failed
        }

        let diagnostics = RecordingDiagnostics(
            id: UUID().uuidString,
            recordingStartTime: startTime,
            recordingEndTime: endTime,
            recordingDuration: endTime.timeIntervalSince(startTime),
            resolution: resolution,
            fps: fps,
            averageWriteLatency: snapshot.averageWriteLatency,
            droppedVideoFrames: snapshot.droppedVideoFrames,
            droppedAudioBuffers: snapshot.droppedAudioBuffers,
            peakMemoryUsageBytes: peakMemory,
            availableStorageBytes: availableStorage,
            checkpointCount: checkpointCount,
            recoveryStatus: recoveryStatus
        )
        await diagnosticsService.save(diagnostics)
    }

    private static func format(seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func startDurationTimer() {
        duration = 0
        durationTask?.cancel()
        durationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                duration += 1
                performanceSnapshot = await service.performanceMonitor.snapshot
            }
        }
    }

    private func stopDurationTimer() {
        durationTask?.cancel()
        durationTask = nil
    }

    deinit {
        durationTask?.cancel()
    }
}
