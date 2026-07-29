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
                // Task 057 item 3: the four figures that decide whether 60fps was
                // actually achieved, available in Release — this screen ships.
                LabeledContent("저장된 파일 FPS", value: String(format: "%.2f fps", diagnostics.savedNominalFrameRate))
                LabeledContent("실제 도착 FPS", value: String(format: "%.1f fps", diagnostics.measuredArrivalFPS))
                LabeledContent("전달된 프레임", value: "\(diagnostics.deliveredVideoFrames)")
                LabeledContent("late drop (카메라)", value: "\(diagnostics.droppedVideoFrames)")
                LabeledContent("stream drop (소비자)", value: "\(diagnostics.droppedBeforeConsumer)")
                LabeledContent("드롭된 프레임", value: "\(diagnostics.droppedVideoFrames + diagnostics.droppedAudioBuffers)")
                LabeledContent("쓰기 지연 시간", value: formattedWriteLatency)
                LabeledContent("메모리 사용량", value: formattedMemory)
                LabeledContent("남은 저장 공간", value: formattedStorage)
            }

            dropReasonSection

            writerStatsSection

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

    /// Task 060 item 1: why AVFoundation discarded frames, from its own attachment.
    /// OutOfBuffers points at buffer retention; FrameWasLate at the delegate queue;
    /// Discontinuity at the capture being interrupted.
    @ViewBuilder
    private var dropReasonSection: some View {
        if let reasons = diagnostics.droppedFrameReasons, !reasons.isEmpty {
            Section("카메라 프레임 드롭 사유") {
                ForEach(reasons.sorted(by: { $0.value > $1.value }), id: \.key) { reason, count in
                    LabeledContent(reason, value: "\(count)")
                }
            }
        }
    }

    /// Task 059 items 1/2/4: the per-writer census, in Release.
    @ViewBuilder
    private var writerStatsSection: some View {
        if let stats = diagnostics.writerStats, !stats.isEmpty {
            Section("Writer 별 append 통계") {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.outputName).font(.headline)
                        Text("시도 \(stat.attempts) · 성공 \(stat.appended) · notReady \(stat.notReady)")
                            .font(.caption)
                        Text(String(format: "수락률 %.1f%% · 평균 append %.2fms",
                                    stat.acceptanceRate * 100, stat.averageAppendMilliseconds))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
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
            recoveryStatus: .completedNormally,
            deliveredVideoFrames: 7_500,
            droppedBeforeConsumer: 0,
            savedNominalFrameRate: 59.94,
            writerStats: nil,
            droppedFrameReasons: ["OutOfBuffers": 291]
        ))
    }
}
