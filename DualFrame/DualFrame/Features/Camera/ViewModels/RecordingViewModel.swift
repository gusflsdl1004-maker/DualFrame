//
//  RecordingViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Exposes recording state to the camera screen and drives the start/stop flow.
/// Owns no capture/writing logic itself — that lives in `RecordingService`.
@MainActor
final class RecordingViewModel: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?

    var statusText: String {
        switch state {
        case .idle: "READY"
        case .preparing: "PREPARING"
        case .recording: "RECORDING"
        case .stopping: "STOPPING"
        case .finished: "FINISHED"
        case .failed: "FAILED"
        }
    }

    var formattedDuration: String {
        let totalSeconds = Int(duration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    var isRecording: Bool { state == .recording }

    private let service: RecordingService
    private var durationTask: Task<Void, Never>?

    init(service: RecordingService) {
        self.service = service
    }

    /// Toggles between starting and stopping — the single button the camera screen exposes.
    func toggleRecording() {
        Task {
            if isRecording {
                await stopRecording()
            } else {
                await startRecording()
            }
        }
    }

    func startRecording() async {
        if state != .preparing {
            state = await service.prepareRecording()
        }
        guard state == .preparing else { return }
        state = await service.startRecording()
        if state == .recording {
            startDurationTimer()
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        state = await service.stopRecording()
        stopDurationTimer()
        if state == .finished {
            lastRecordingURL = await service.outputFileURL()
        }
    }

    private func startDurationTimer() {
        duration = 0
        durationTask?.cancel()
        durationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                duration += 1
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
