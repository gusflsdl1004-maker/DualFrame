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
                // Task 077: the A/B condition. Read this before the drop counts below —
                // they mean different things on either side.
                //
                // Task 082 removed the second preview and its `PreviewExperimentMode`
                // enum, but records written during the experiment still carry the raw
                // string, so it is mapped here rather than parsed. Deleting the display
                // would have silently changed what those older records mean (CLAUDE.md
                // rule 58 — existing data is never migrated or hidden).
                if let mode = diagnostics.previewExperimentMode {
                    LabeledContent("프리뷰 조건", value: Self.previewConditionTitle(mode))
                } else if let secondPreview = diagnostics.secondPreviewEnabled {
                    LabeledContent("Short 프리뷰", value: secondPreview ? "켬 (프리뷰 2개)" : "끔 (프리뷰 1개)")
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
                    // Task 068: which crop implementation ran. Absent on Long-only
                    // recordings is expected — nothing was cropped.
                    if let backend = diagnostics.cropBackend {
                        LabeledContent("Short crop 구현", value: backend.title)
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

            // Task 069: post-processing generation, kept apart from the real-time
            // figures above — an offline pass is measured against wall clock, not the
            // frame interval.
            if let generation = diagnostics.shortGeneration {
                Section {
                    // The headline figure: it decides how long an ad has to run for
                    // "ad ends = generation done" to hold.
                    LabeledContent("생성 속도(배속)", value: String(format: "%.2f×", generation.speedRatio))
                        .font(.body.bold())
                    LabeledContent("총 생성 시간", value: String(format: "%.2f초", generation.totalSeconds))
                    LabeledContent("생성 처리 FPS", value: String(format: "%.1f fps", generation.generationFPS))
                    if let sourceDuration = generation.sourceDurationSeconds {
                        LabeledContent("원본 길이", value: String(format: "%.1f초", sourceDuration))
                    }
                    // Sized from the speed this run actually achieved, so the ad length
                    // is chosen from measurement rather than a guess.
                    if let estimate = generation.estimatedSeconds(forSourceDuration: 180) {
                        LabeledContent("3분 영상 환산", value: String(format: "%.0f초", estimate))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("쇼츠 생성 (후처리)")
                } footer: {
                    Text("배속은 원본 영상 길이 ÷ 생성 시간입니다. 8.5×면 3분 영상이 약 21초에 생성됩니다.")
                }

                // Task 073 P1-8: where the time actually goes. The share matters more
                // than the absolute seconds — it says which stage to attack, and
                // `설명되지 않은 시간` says whether the stages are the problem at all or
                // the way they are sequenced is.
                Section {
                    ForEach(generation.stageShares, id: \.name) { stage in
                        LabeledContent(stage.name) {
                            Text(String(format: "%.1f초 (%.0f%%)", stage.seconds, stage.share * 100))
                                .font(.callout.monospacedDigit())
                        }
                    }
                    LabeledContent("설명되지 않은 시간") {
                        Text(String(format: "%.1f초", generation.unaccountedSeconds))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(generation.unaccountedSeconds > generation.totalSeconds * 0.3 ? Color.orange : Color.secondary)
                    }
                } header: {
                    Text("생성 단계별 시간")
                } footer: {
                    Text("Reader는 원본 4K60 HEVC 디코드입니다. 한 단계가 70% 이상이면 그 단계가 병목입니다. '설명되지 않은 시간'이 크면 단계 자체가 아니라 순차 실행 구조(디코드→크롭→인코딩이 서로를 기다림)가 원인입니다.")
                }

                Section("쇼츠 생성 상세") {
                    LabeledContent("결과", value: generation.succeeded ? "성공" : "실패")
                        .foregroundStyle(generation.succeeded ? Color.primary : Color.red)
                    LabeledContent("생성 엔진", value: generation.backend.title)
                    // Task 075 item 9: without this, two generation times from
                    // different quality settings look like a regression.
                    if let quality = generation.quality {
                        LabeledContent("생성 품질", value: "\(quality.title) · \(quality.subtitle)")
                    }
                    LabeledContent("프레임 수", value: "\(generation.frameCount)")
                    LabeledContent("crop 평균", value: String(format: "%.2fms", generation.averageCropMilliseconds))
                    LabeledContent("인코딩 평균", value: String(format: "%.2fms", generation.averageEncodeMilliseconds))
                }

                // The two frame rates side by side. They answer different questions and
                // are produced by different pipelines now — capture for the long-form
                // file, post-processing for the short-form one — so seeing them apart
                // is what makes a regression in either one attributable.
                Section("저장된 영상 FPS") {
                    LabeledContent("Long (촬영)", value: String(format: "%.2f fps", diagnostics.savedNominalFrameRate))
                    if let shortRate = generation.outputFrameRate {
                        LabeledContent("Short (후처리)", value: String(format: "%.2f fps", shortRate))
                    } else {
                        LabeledContent("Short (후처리)", value: "—")
                    }
                }
            }

            dropReasonSection

            dropDetailSection

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

    /// Task 067: the first few drops in full, plus the union of attachment keys seen.
    ///
    /// The key list is the part worth reading first — it is the empirical answer to
    /// "which attachments does AVFoundation actually put on a dropped buffer", which no
    /// header can give, since CoreMedia declares only two and implementations may attach
    /// more. `backlog` in each sample is our own in-flight count at that instant: if it
    /// is 0 or 1 while frames are being dropped as late, the delay is not ours.
    @ViewBuilder
    private var dropDetailSection: some View {
        if let keys = diagnostics.dropAttachmentKeys, !keys.isEmpty {
            Section("드롭 버퍼 attachment 키 (실제 관측)") {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.caption.monospaced())
                }
            }
        }
        if let samples = diagnostics.dropSamples, !samples.isEmpty {
            Section("드롭 상세 (처음 \(samples.count)건)") {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    Text(sample)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
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

    /// Titles for the Task 077 preview conditions, kept as a plain string map now that the
    /// enum itself is gone (Task 082). Only records written during that experiment reach
    /// this; anything else falls through to the raw value rather than being dropped.
    private static func previewConditionTitle(_ rawValue: String) -> String {
        switch rawValue {
        case "single": "① 프리뷰 1개 (기준)"
        case "stacked": "② 프리뷰 2개"
        case "stackedNoConnection": "③ 2개 · 연결 없음"
        default: rawValue
        }
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
            thermalStateAtEnd: "fair",
            dropSamples: ["[Task067-Drop] reason=FrameWasLate pts=12.3456s uptime=8421.117 thermal=fair backlog=1 attachments: DroppedFrameReason=FrameWasLate"],
            dropAttachmentKeys: ["DroppedFrameReason"],
            cropBackend: .videoToolbox,
            secondPreviewEnabled: true,
            previewExperimentMode: "stacked",
            shortGeneration: ShortGenerationMetrics(
                backend: .videoToolbox,
                frameCount: 7_500,
                totalSeconds: 41.2,
                cropSeconds: 3.1,
                encodeSeconds: 28.7,
                succeeded: true,
                sourceDurationSeconds: 125,
                readerSeconds: 96.0,
                finishSeconds: 4.2,
                quality: .fast,
                outputFrameRate: 59.94
            )
        ))
    }
}
