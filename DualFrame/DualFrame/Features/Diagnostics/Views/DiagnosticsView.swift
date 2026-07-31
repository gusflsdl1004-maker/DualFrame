//
//  DiagnosticsView.swift
//  DualFrame
//

import SwiftUI

/// Lists every saved recording session's diagnostics, newest first (requirement 7).
/// Pushed from the Settings screen, so it has no `NavigationStack` of its own
/// (matches `ExternalStorageView`/`RecordingQualityView`).
struct DiagnosticsView: View {
    @StateObject private var viewModel = DiagnosticsViewModel()
    /// Task 063 item 4: the capture-stage experiment switch. Local `@State` seeded from
    /// the store and written straight back on change — no view model, because nothing
    /// else in the app reacts to it: `CameraService` re-reads the store before every
    /// recording, so the next recording simply picks up whatever is selected here.
    @State private var lateFrameHandling = LateFrameHandlingSettingsService().load().mode
    private let lateFrameHandlingSettingsService = LateFrameHandlingSettingsService()
    /// Task 064: the encoder-path experiment. Same pattern — `RecordingService` re-reads
    /// the store when it builds each writer, so the next recording picks this up.
    @State private var encoderSettings = VideoEncoderSettingsService().load()
    private let encoderSettingsService = VideoEncoderSettingsService()
    /// Task 068: CoreImage ↔ VideoToolbox crop. Pinned by `RecordingService` when the
    /// writers are built, so changing it here applies from the next recording.
    @State private var cropBackend = CropBackendSettingsService().load().backend
    private let cropBackendSettingsService = CropBackendSettingsService()
    /// Task 071: plan and mock-ad behaviour. Placed here with the other switches rather
    /// than in user-facing settings — a locally flippable "Pro" is a development
    /// affordance, not an entitlement.
    @State private var planSettings = UserPlanSettingsService().load()
    private let planSettingsService = UserPlanSettingsService()
    /// Task 074 P2: generation quality. Not plan-gated here — `ExportManager` is the
    /// only type that reads the plan, and generation behaves identically for everyone.
    @State private var generationQuality = ShortGenerationQualitySettingsService().load().quality
    private let generationQualityService = ShortGenerationQualitySettingsService()

    var body: some View {
        List {
            Section {
                Picker("늦은 프레임 처리", selection: $lateFrameHandling) {
                    ForEach(LateFrameHandling.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text(lateFrameHandling.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("캡처 실험 (Task 063)")
            } footer: {
                Text("이 설정은 다음 녹화부터 적용되며, 각 녹화 기록에 어떤 설정이었는지 함께 저장됩니다. 두 설정으로 각각 녹화한 뒤 아래 비교 화면에서 드롭 사유를 대조하세요.")
            }

            Section {
                Picker("코덱", selection: $encoderSettings.codec) {
                    ForEach(VideoCodecPreference.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                Text(encoderSettings.codec.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("키프레임 간격", selection: $encoderSettings.keyFrameInterval) {
                    ForEach(KeyFrameInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                Text(encoderSettings.keyFrameInterval.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("인코더 실험 (Task 064)")
            } footer: {
                Text("H.264 Level 5.1은 4K에서 초당 30프레임이 한계입니다(4K 1프레임 = 32,400 매크로블록, Level 5.1 = 983,040 MB/s). iPhone의 하드웨어 H.264 인코더는 Level 5.1을 넘지 않으므로 4K60은 HEVC가 필요합니다. 비트레이트는 설정 → 녹화 화질에서 '절반'을 고르면 비교할 수 있습니다.")
            }

            Section {
                Picker("Short crop 구현", selection: $cropBackend) {
                    ForEach(CropBackend.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text(cropBackend.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Short crop 실험 (Task 068)")
            } footer: {
                Text("Long만 저장에는 영향이 없습니다(crop을 하지 않음). Long + Short에서만 차이가 납니다. VideoToolbox 선택 시 Short 영상의 색·밝기와 선명도를 반드시 눈으로 확인하세요 — 빌드가 판정할 수 없는 항목입니다. 이상하면 CoreImage로 되돌리면 즉시 원복됩니다.")
            }

            Section {
                Picker("플랜", selection: $planSettings.plan) {
                    ForEach(UserPlan.allCases) { plan in
                        Text(plan.title).tag(plan)
                    }
                }
                .pickerStyle(.segmented)
                Picker("모의 광고 결과", selection: Binding(
                    get: { planSettings.mockAdOutcome ?? .reward },
                    set: { planSettings.mockAdOutcome = $0 }
                )) {
                    ForEach(MockAdOutcome.allCases) { outcome in
                        Text(outcome.title).tag(outcome)
                    }
                }
                Picker("숏폼 생성 품질", selection: $generationQuality) {
                    ForEach(ShortGenerationQuality.allCases) { quality in
                        Text("\(quality.title) · \(quality.subtitle)").tag(quality)
                    }
                }
                Text(generationQuality.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(generationQuality.estimatedDurationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("플랜 / 광고 (Task 071)")
            } footer: {
                Text("무료 플랜은 카메라롤 저장 전에 리워드 광고를 봅니다. '도중 닫기'와 '로드 실패'는 저장을 거부하는 경로로, 반드시 두 경우 모두 앱 내 영상이 그대로 남는지 확인하세요. 녹화와 쇼츠 생성은 플랜과 무관하게 동작합니다.")
            }

            // Task 062: the two conditions side by side, which is what the comparison
            // actually needs — scrolling between two detail screens loses the diff.
            Section {
                NavigationLink {
                    DiagnosticsComparisonView(sessions: viewModel.sessions)
                } label: {
                    Label("Long vs Long+Short 비교", systemImage: "square.split.2x1")
                }
            }

            // Task 063: the empty state used to be a full-screen `.overlay`, which on a
            // fresh install covered the whole list — including the capture-experiment
            // switch above, which is precisely what has to be reachable *before* the
            // first recording. Moved inside the list so it replaces only the session
            // rows it is talking about.
            if viewModel.sessions.isEmpty {
                Section {
                    ContentUnavailableView("녹화 기록이 없습니다", systemImage: "chart.bar.doc.horizontal")
                }
            } else {
                ForEach(viewModel.sessions) { session in
                    NavigationLink {
                        DiagnosticsDetailView(diagnostics: session)
                    } label: {
                        sessionRow(session)
                    }
                }
            }
        }
        .navigationTitle("진단")
        .onChange(of: lateFrameHandling) { _, newValue in
            lateFrameHandlingSettingsService.save(LateFrameHandlingSettings(mode: newValue))
        }
        .onChange(of: encoderSettings) { _, newValue in
            encoderSettingsService.save(newValue)
        }
        .onChange(of: cropBackend) { _, newValue in
            cropBackendSettingsService.save(CropBackendSettings(backend: newValue))
        }
        .onChange(of: planSettings) { _, newValue in
            planSettingsService.save(newValue)
        }
        .onChange(of: generationQuality) { _, newValue in
            generationQualityService.save(ShortGenerationQualitySettings(quality: newValue))
        }
        .task {
            await viewModel.refresh()
        }
    }

    private func conditionLabel(_ session: RecordingDiagnostics) -> String {
        // Task 069: the writer count alone no longer identifies the condition. Dual now
        // records with a single writer and derives the short-form output afterwards, so
        // every new recording reports one writer. `shortGeneration` being present is
        // what marks a Long + Short session now; the writer count is kept only to read
        // records written before Task 069, where two writers really did run.
        let outputs: String
        if session.shortGeneration != nil {
            outputs = "Long + Short (후처리)"
        } else if (session.writerStats?.count ?? 0) >= 2 {
            outputs = "Long + Short (실시간)"
        } else if (session.writerStats?.count ?? 0) == 1 {
            outputs = "Long Only"
        } else {
            outputs = "조건 미기록"
        }
        // Task 063: the capture setting is part of the condition, so a run can be told
        // apart from its own A/B counterpart without opening the detail screen.
        guard let handling = session.lateFrameHandling else { return outputs }
        return "\(outputs) · \(handling.shortTitle)"
    }

    private func sessionRow(_ session: RecordingDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.recordingStartTime.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            Text("\(formattedDuration(session.recordingDuration)) · \(session.resolution.title) · \(session.fps.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Task 062: which condition this recording was, derived from how many
            // writers actually ran — so the two runs are told apart in the list.
            Text(conditionLabel(session))
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(session.recoveryStatus.title)
                .font(.caption2)
                .foregroundStyle(session.recoveryStatus == .failed ? .red : .secondary)
        }
        .padding(.vertical, 2)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView()
    }
}
