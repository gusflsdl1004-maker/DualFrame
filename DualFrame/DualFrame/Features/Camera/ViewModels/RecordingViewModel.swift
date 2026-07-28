//
//  RecordingViewModel.swift
//  DualFrame
//

import Combine
import Foundation

/// Exposes recording state to the camera screen. Owns no capture/writing logic itself —
/// that lives in `RecordingService`.
@MainActor
final class RecordingViewModel: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var duration: TimeInterval = 0

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

    private let service: RecordingService
    private var durationTask: Task<Void, Never>?

    init(service: RecordingService = RecordingService()) {
        self.service = service
    }

    func prepareRecording() async {
        state = await service.prepareRecording()
    }

    func startRecording() async {
        state = await service.startRecording()
        if state == .recording {
            startDurationTimer()
        }
    }

    func stopRecording() async {
        state = await service.stopRecording()
        stopDurationTimer()
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
