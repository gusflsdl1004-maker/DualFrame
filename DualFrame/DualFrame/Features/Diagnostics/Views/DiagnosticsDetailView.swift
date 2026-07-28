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
            Section("녹화") {
                LabeledContent("길이", value: formattedDuration)
                LabeledContent("해상도", value: diagnostics.resolution.title)
                LabeledContent("FPS", value: diagnostics.fps.title)
            }

            Section("성능") {
                LabeledContent("드롭된 프레임", value: "\(diagnostics.droppedVideoFrames + diagnostics.droppedAudioBuffers)")
                LabeledContent("쓰기 지연 시간", value: formattedWriteLatency)
                LabeledContent("메모리 사용량", value: formattedMemory)
                LabeledContent("남은 저장 공간", value: formattedStorage)
            }

            Section("복구") {
                LabeledContent("체크포인트 저장 횟수", value: "\(diagnostics.checkpointCount)")
                LabeledContent("복구 상태", value: diagnostics.recoveryStatus.title)
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
