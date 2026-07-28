//
//  DiagnosticsDetailView.swift
//  DualFrame
//

import SwiftUI

/// Read-only detail screen for one recording session's diagnostics (requirement 8).
struct DiagnosticsDetailView: View {
    let diagnostics: RecordingDiagnostics

    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("Duration", value: formattedDuration)
                LabeledContent("Resolution", value: diagnostics.resolution.title)
                LabeledContent("FPS", value: diagnostics.fps.title)
            }

            Section("Performance") {
                LabeledContent("Dropped Frames", value: "\(diagnostics.droppedVideoFrames + diagnostics.droppedAudioBuffers)")
                LabeledContent("Write Latency", value: formattedWriteLatency)
                LabeledContent("Memory Usage", value: formattedMemory)
                LabeledContent("Storage Remaining", value: formattedStorage)
            }

            Section("Recovery") {
                LabeledContent("Checkpoint Count", value: "\(diagnostics.checkpointCount)")
                LabeledContent("Recovery Status", value: diagnostics.recoveryStatus.title)
            }
        }
        .navigationTitle(diagnostics.recordingStartTime.formatted(date: .abbreviated, time: .shortened))
    }

    private var formattedDuration: String {
        let totalSeconds = Int(diagnostics.recordingDuration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private var formattedWriteLatency: String {
        String(format: "%.0f ms", diagnostics.averageWriteLatency * 1_000)
    }

    private var formattedMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(diagnostics.peakMemoryUsageBytes), countStyle: .memory)
    }

    private var formattedStorage: String {
        ByteCountFormatter.string(fromByteCount: diagnostics.availableStorageBytes, countStyle: .file)
    }
}

#Preview {
    NavigationStack {
        DiagnosticsDetailView(diagnostics: RecordingDiagnostics(
            id: UUID().uuidString,
            recordingStartTime: Date(),
            recordingEndTime: Date(),
            recordingDuration: 125,
            resolution: .fullHD,
            fps: .fps30,
            averageWriteLatency: 0.012,
            droppedVideoFrames: 2,
            droppedAudioBuffers: 0,
            peakMemoryUsageBytes: 180_000_000,
            availableStorageBytes: 12_000_000_000,
            checkpointCount: 24,
            recoveryStatus: .completedNormally
        ))
    }
}
