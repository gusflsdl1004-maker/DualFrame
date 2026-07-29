//
//  RecordingPerformanceMonitor.swift
//  DualFrame
//

import Foundation
import Darwin

/// A category of abnormal condition the monitor can detect.
nonisolated enum RecordingAnomalyType: String {
    case highMemoryUsage
    case droppedVideoFrame
    case droppedAudioBuffer
    case highWriteLatency
    case queueBacklog
    case lowStorage
}

/// A single logged abnormal event. Logging never stops or alters recording —
/// see requirement 8/10: monitoring only observes and reports.
nonisolated struct RecordingAnomaly: Equatable {
    let type: RecordingAnomalyType
    let detail: String
    let timestamp: Date
}

/// A point-in-time read of the recording pipeline's health, for on-screen display
/// and for the Performance Report.
nonisolated struct RecordingPerformanceSnapshot: Equatable {
    var duration: TimeInterval = 0
    var memoryUsageBytes: UInt64 = 0
    var droppedVideoFrames: Int = 0
    var droppedAudioBuffers: Int = 0
    var averageWriteLatency: TimeInterval = 0
    var queueBacklog: Int = 0
}

/// Observes the recording pipeline's health during a recording — duration, memory,
/// dropped frames/buffers, write latency, and how far the append queue is falling
/// behind — and checks free disk space before recording starts.
///
/// This type never stops or alters a recording by itself (requirements 8, 9, 10):
/// it only records counters, logs anomalies, and exposes a snapshot for display and
/// for the Performance Report. Every operation here is a cheap counter increment or
/// an occasional (every 2s) poll, to keep overhead minimal (requirement 11).
actor RecordingPerformanceMonitor {
    private(set) var snapshot = RecordingPerformanceSnapshot()
    private(set) var anomalies: [RecordingAnomaly] = []
    private(set) var lowStorageWarning: String?
    /// The highest memory reading seen since `startMonitoring()` — for the
    /// diagnostics report, where the peak matters more than any single sample.
    private(set) var peakMemoryUsageBytes: UInt64 = 0

    private var recordingStartTime: Date?
    private var droppedVideoFrameCount = 0
    private var droppedAudioBufferCount = 0
    private var writeLatencies: [TimeInterval] = []
    private var spawnedFrameCount = 0
    private var completedFrameCount = 0
    private var monitoringTask: Task<Void, Never>?

    private let memoryWarningThresholdBytes: UInt64 = 500 * 1_024 * 1_024
    private let writeLatencyWarningThreshold: TimeInterval = 0.05
    private let queueBacklogWarningThreshold = 10
    private let lowStorageThresholdBytes: Int64 = 500 * 1_024 * 1_024

    // MARK: - Lifecycle

    func startMonitoring() {
        recordingStartTime = Date()
        droppedVideoFrameCount = 0
        droppedAudioBufferCount = 0
        writeLatencies.removeAll()
        spawnedFrameCount = 0
        completedFrameCount = 0
        droppedBeforeConsumerCount = 0
        deliveredVideoFrameCount = 0
        dropReasonCounts.removeAll()
        anomalies.removeAll()
        snapshot = RecordingPerformanceSnapshot()
        peakMemoryUsageBytes = 0

        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshSnapshot()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        refreshSnapshot()
    }

    // MARK: - Event reporting (called from the capture/recording pipeline)

    /// Task 057 item 3: frames the delivery stream refused because the consumer was
    /// behind. Distinct from `recordDroppedVideoFrame`, which is AVFoundation dropping
    /// before the delegate. Counted in every configuration so Release can be judged.
    private(set) var droppedBeforeConsumerCount = 0
    /// Frames that actually reached `RecordingService`.
    private(set) var deliveredVideoFrameCount = 0

    /// Task 060 item 1: tally of `kCMSampleBufferAttachmentKey_DroppedFrameReason`
    /// values, so the reason AVFoundation gives is reported rather than guessed at.
    private(set) var dropReasonCounts: [String: Int] = [:]

    func recordDropReason(_ reason: String) {
        dropReasonCounts[reason, default: 0] += 1
    }

    func recordDroppedBeforeConsumer() {
        droppedBeforeConsumerCount += 1
    }

    func recordDroppedVideoFrame() {
        droppedVideoFrameCount += 1
        logAnomaly(.droppedVideoFrame, detail: "Dropped video frame (total: \(droppedVideoFrameCount))")
    }

    func recordDroppedAudioBuffer() {
        droppedAudioBufferCount += 1
        logAnomaly(.droppedAudioBuffer, detail: "Dropped audio buffer (total: \(droppedAudioBufferCount))")
    }

    func recordWriteLatency(_ latency: TimeInterval) {
        writeLatencies.append(latency)
        if writeLatencies.count > 200 {
            writeLatencies.removeFirst(writeLatencies.count - 200)
        }
        if latency > writeLatencyWarningThreshold {
            logAnomaly(.highWriteLatency, detail: String(format: "Write took %.0fms", latency * 1_000))
        }
    }

    /// Call when a sample buffer is handed off from the capture output — before the
    /// asynchronous append into `RecordingService` even begins.
    /// Task 052: batched replacement for the per-buffer `frameSpawned`/`frameCompleted`
    /// pair. Those were two `await`s on this actor for every single sample buffer —
    /// at 60fps video plus audio that is hundreds of suspensions a second spent on two
    /// integer increments, on the exact path that has to keep up with the camera.
    /// `SampleBufferOutputForwarder` now counts locally and calls this every 30 frames.
    ///
    /// The spawned/completed pair existed to detect an append backlog. That job now
    /// belongs to the bounded `AsyncStream` in the forwarder, which reports the frames
    /// it had to discard directly.
    func framesProcessed(_ count: Int) {
        spawnedFrameCount += count
        completedFrameCount += count
        deliveredVideoFrameCount += count
    }

    func frameSpawned() {
        spawnedFrameCount += 1
    }

    /// Call once that sample buffer has finished being appended (or dropped).
    func frameCompleted() {
        completedFrameCount += 1
        let backlog = max(0, spawnedFrameCount - completedFrameCount)
        if backlog > queueBacklogWarningThreshold {
            logAnomaly(.queueBacklog, detail: "Append queue backlog: \(backlog)")
        }
    }

    // MARK: - Storage check (requirement 13)

    /// Checks free space on the volume recordings are written to. Only warns —
    /// never blocks or stops recording.
    @discardableResult
    func checkAvailableStorage(
        directory: URL = FileManager.default.temporaryDirectory,
        minimumFreeBytes: Int64? = nil
    ) -> String? {
        let threshold = minimumFreeBytes ?? lowStorageThresholdBytes
        guard let available = currentAvailableStorageBytes(directory: directory) else {
            lowStorageWarning = nil
            return nil
        }

        guard available < threshold else {
            lowStorageWarning = nil
            return nil
        }

        let formatted = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        let warning = "저장 공간 부족: \(formatted) 남음"
        lowStorageWarning = warning
        logAnomaly(.lowStorage, detail: warning)
        return warning
    }

    /// The raw available space, for the diagnostics report — unlike
    /// `checkAvailableStorage`, this doesn't compare against a threshold or log anything.
    func currentAvailableStorageBytes(directory: URL = FileManager.default.temporaryDirectory) -> Int64? {
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Private

    private func refreshSnapshot() {
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? snapshot.duration
        let memory = Self.currentMemoryUsageBytes()
        let averageLatency = writeLatencies.isEmpty ? 0 : writeLatencies.reduce(0, +) / Double(writeLatencies.count)
        let backlog = max(0, spawnedFrameCount - completedFrameCount)

        snapshot = RecordingPerformanceSnapshot(
            duration: duration,
            memoryUsageBytes: memory,
            droppedVideoFrames: droppedVideoFrameCount,
            droppedAudioBuffers: droppedAudioBufferCount,
            averageWriteLatency: averageLatency,
            queueBacklog: backlog
        )

        peakMemoryUsageBytes = max(peakMemoryUsageBytes, memory)

        if memory > memoryWarningThresholdBytes {
            logAnomaly(.highMemoryUsage, detail: "Memory usage: \(memory / 1_024 / 1_024) MB")
        }
    }

    private func logAnomaly(_ type: RecordingAnomalyType, detail: String) {
        anomalies.append(RecordingAnomaly(type: type, detail: detail, timestamp: Date()))
        if anomalies.count > 100 {
            anomalies.removeFirst(anomalies.count - 100)
        }
    }

    private nonisolated static func currentMemoryUsageBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }
}
