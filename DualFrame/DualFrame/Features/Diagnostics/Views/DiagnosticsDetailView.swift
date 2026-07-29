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
                // Task 063 item 4: which capture setting produced these numbers. Absent
                // on anything recorded before Task 063, which is exactly why those
                // measurements could not be attributed to a setting.
                if let handling = diagnostics.lateFrameHandling {
                    LabeledContent("늦은 프레임 처리", value: handling.title)
                }
            }

            // Task 064: what the encoder was asked for, and what it actually produced.
            // `저장된 포맷` is parsed out of the written file, so the level shown is
            // VideoToolbox's own choice — for H.264, Level 5.1 at 4K means 30fps was the
            // ceiling no matter how many frames arrived.
            if diagnostics.videoCodecPreference != nil || diagnostics.savedVideoFormat != nil {
                Section("인코더") {
                    if let codec = diagnostics.videoCodecPreference {
                        LabeledContent("코덱 설정", value: codec.title)
                    }
                    if let interval = diagnostics.keyFrameIntervalSeconds {
                        LabeledContent("키프레임 간격", value: "\(interval)초")
                    }
                    if let preset = diagnostics.bitratePreset {
                        LabeledContent("비트레이트 프리셋", value: preset.title)
                    }
                    // Task 065 item 1: what the selection decided, before the file
                    // existed. If this says `hvc1` but 저장된 포맷 below says `avc1`,
                    // something overrode the codec after we asked for it; if this
                    // itself says `avc1`, the selection is what needs fixing — and the
                    // dimensions@fps in the line say why (a 4K30 decision is correct).
                    if let decisions = diagnostics.encoderDecisions, !decisions.isEmpty {
                        ForEach(decisions, id: \.self) { decision in
                            Text(decision)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Task 065: every writer's actual result, not just the long-form's.
                    if let formats = diagnostics.savedVideoFormatsByProfile, !formats.isEmpty {
                        ForEach(formats.sorted(by: { $0.key < $1.key }), id: \.key) { name, format in
                            LabeledContent(name) {
                                Text(format)
                                    .font(.caption.monospaced())
                            }
                            if let rate = diagnostics.savedFrameRatesByProfile?[name] {
                                LabeledContent("  └ 저장 FPS", value: String(format: "%.2f fps", rate))
                            }
                        }
                    } else if let format = diagnostics.savedVideoFormat, !format.isEmpty {
                        LabeledContent("저장된 포맷", value: format)
                            .font(.caption.monospaced())
                    }
                }
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

            // Task 066 item 1: shown above the drop reasons on purpose — if the thermal
            // state climbed during the recording, the drop counts below have to be read
            // in that light rather than as a code problem.
            if let start = diagnostics.thermalStateAtStart {
                Section("발열 상태") {
                    LabeledContent("시작", value: start)
                    if let peak = diagnostics.peakThermalState {
                        LabeledContent("최고", value: peak)
                            .foregroundStyle(peak == "nominal" ? Color.primary : Color.orange)
                    }
                    if let end = diagnostics.thermalStateAtEnd {
                        LabeledContent("종료", value: end)
                    }
                }
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
                        // Task 061 items 1/2: zero for Long-form, non-zero for
                        // Short-form — the gap is the extra per-frame cost of dual.
                        if stat.averageCropSeconds > 0 {
                            Text(String(format: "crop %.2fms (render %.2f · pool %.2f) · 프레임당 합계 %.2fms",
                                        stat.averageCropMilliseconds,
                                        stat.averageCropRenderMilliseconds,
                                        stat.averageCropPoolMilliseconds,
                                        stat.totalPerFrameMilliseconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
            droppedFrameReasons: ["OutOfBuffers": 291],
            lateFrameHandling: .discard,
            videoCodecPreference: .auto,
            keyFrameIntervalSeconds: 1,
            bitratePreset: .high,
            savedVideoFormat: "hvc1 profile=1 tier=Main level=5.1",
            encoderDecisions: ["Long-form: auto 3840x2160@60 → hvc1"],
            savedVideoFormatsByProfile: ["Long-form": "hvc1 profile=1 tier=Main level=5.1"],
            savedFrameRatesByProfile: ["Long-form": 59.94],
            thermalStateAtStart: "nominal",
            peakThermalState: "fair",
            thermalStateAtEnd: "fair"
        ))
    }
}
