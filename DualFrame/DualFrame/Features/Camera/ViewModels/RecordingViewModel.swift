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
    private var durationTask: Task<Void, Never>?

    init(service: RecordingService) {
        self.service = service
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
            startDurationTimer()
        }
    }

    func stopRecording(expectsAudioTrack: Bool) async {
        guard state == .recording else { return }
        state = await service.stopRecording(expectsAudioTrack: expectsAudioTrack)
        stopDurationTimer()
        lastValidationResult = await service.lastValidationResult

        if state == .finished {
            lastRecordingURL = await service.outputFileURL()
        } else {
            errorMessage = await service.lastError?.message
        }
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
