//
//  DiagnosticsComparisonView.swift
//  DualFrame
//

import SwiftUI

/// Task 062: Long Only and Long + Short, side by side, from the two most recent
/// recordings of each kind.
///
/// The condition is derived from `writerStats.count` rather than a stored flag — one
/// writer means Long only, two means Long + Short. That is ground truth: it is the
/// number of writers the recording actually ran, not a setting that might have been
/// changed afterwards.
///
/// The point of the screen is the *difference* between the two columns. Both were
/// running the same camera at the same format, so any row that differs is caused by the
/// short-form path and nothing else.
struct DiagnosticsComparisonView: View {
    let sessions: [RecordingDiagnostics]

    /// Task 063 item 4: which capture setting to compare *within*. `nil` means "newest
    /// of each, whatever it was set to" — the pre-Task-063 behaviour, and still the
    /// right default for someone who is not running the A/B.
    ///
    /// Filtering here rather than adding a third and fourth column keeps the screen
    /// two-column while still giving the full 2×2: pick `discard`, read the pair, pick
    /// `queue`, read the other pair.
    @State private var handlingFilter: LateFrameHandling?

    private var filteredSessions: [RecordingDiagnostics] {
        guard let handlingFilter else { return sessions }
        return sessions.filter { $0.lateFrameHandling == handlingFilter }
    }

    /// Newest recording that ran a single writer.
    private var longOnly: RecordingDiagnostics? {
        filteredSessions.first { ($0.writerStats?.count ?? 0) == 1 }
    }

    /// Newest recording that ran both writers.
    private var longAndShort: RecordingDiagnostics? {
        filteredSessions.first { ($0.writerStats?.count ?? 0) >= 2 }
    }

    var body: some View {
        Form {
            Section("캡처 설정 필터") {
                Picker("늦은 프레임 처리", selection: $handlingFilter) {
                    Text("전체").tag(LateFrameHandling?.none)
                    ForEach(LateFrameHandling.allCases) { mode in
                        Text(mode.shortTitle).tag(LateFrameHandling?.some(mode))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if longOnly == nil || longAndShort == nil {
                Section {
                    ContentUnavailableView(
                        "비교할 기록이 부족합니다",
                        systemImage: "square.split.2x1",
                        description: Text(handlingFilter == nil
                            ? "Long만 저장과 Long + Short 저장으로 각각 한 번씩 녹화하면 여기서 비교됩니다."
                            : "이 캡처 설정으로는 아직 두 조건이 모두 녹화되지 않았습니다.")
                    )
                }
            } else {
                Section("측정 조건") {
                    comparisonRow("녹화 길이",
                                  format(longOnly?.recordingDuration),
                                  format(longAndShort?.recordingDuration))
                    comparisonRow("설정",
                                  "\(longOnly?.resolution.title ?? "--") \(longOnly?.fps.title ?? "")",
                                  "\(longAndShort?.resolution.title ?? "--") \(longAndShort?.fps.title ?? "")")
                    // Task 063 item 4: if these two differ, the columns are not
                    // comparable — the difference between them is the capture setting,
                    // not the short-form path. Shown here so that can never be missed.
                    comparisonRow("늦은 프레임 처리",
                                  longOnly?.lateFrameHandling?.shortTitle ?? "—",
                                  longAndShort?.lateFrameHandling?.shortTitle ?? "—")
                    // Task 064: same warning applies — if these differ, the columns
                    // measure two different encoders, not the short-form path.
                    comparisonRow("코덱 설정",
                                  longOnly?.videoCodecPreference?.shortTitle ?? "—",
                                  longAndShort?.videoCodecPreference?.shortTitle ?? "—")
                    // Task 068: Long Only never crops, so its column is "—" by
                    // construction. The value that matters is the right-hand one.
                    comparisonRow("Short crop 구현",
                                  longOnly?.cropBackend?.shortTitle ?? "—",
                                  longAndShort?.cropBackend?.shortTitle ?? "—")
                    comparisonRow("저장된 코덱/레벨",
                                  codecAndLevel(longOnly?.savedVideoFormat),
                                  codecAndLevel(longAndShort?.savedVideoFormat))
                }

                Section("결과") {
                    comparisonRow("저장된 파일 FPS",
                                  fps(longOnly?.savedNominalFrameRate),
                                  fps(longAndShort?.savedNominalFrameRate))
                    comparisonRow("실제 도착 FPS",
                                  fps(longOnly?.measuredArrivalFPS),
                                  fps(longAndShort?.measuredArrivalFPS))
                    comparisonRow("전달된 프레임",
                                  count(longOnly?.deliveredVideoFrames),
                                  count(longAndShort?.deliveredVideoFrames))
                }

                // The section that decides the next step: if the reason distribution is
                // the same in both columns, the short-form path is not what causes the
                // drops — it only makes an existing limit worse.
                Section("카메라 드롭 사유") {
                    ForEach(["FrameWasLate", "OutOfBuffers", "Discontinuity"], id: \.self) { reason in
                        comparisonRow(reason,
                                      count(longOnly?.droppedFrameReasons?[reason] ?? 0),
                                      count(longAndShort?.droppedFrameReasons?[reason] ?? 0))
                    }
                    comparisonRow("stream drop (소비자)",
                                  count(longOnly?.droppedBeforeConsumer),
                                  count(longAndShort?.droppedBeforeConsumer))
                }

                // Requirement: shown for Long + Short only. Long Only has no short-form
                // writer, so there is nothing to show and the column stays "—".
                Section("Short 전용 비용 (Long + Short 에만 존재)") {
                    let shortStat = longAndShort?.writerStats?.first { $0.averageCropSeconds > 0 }
                    comparisonRow("crop 평균", "—", ms(shortStat?.averageCropMilliseconds))
                    comparisonRow("  └ CIContext render", "—", ms(shortStat?.averageCropRenderMilliseconds))
                    comparisonRow("  └ PixelBuffer 생성", "—", ms(shortStat?.averageCropPoolMilliseconds))
                    comparisonRow("Short append 평균", "—", ms(shortStat?.averageAppendMilliseconds))
                }

                Section("Writer append 평균") {
                    comparisonRow("Long-form",
                                  ms(longFormStat(longOnly)?.averageAppendMilliseconds),
                                  ms(longFormStat(longAndShort)?.averageAppendMilliseconds))
                    comparisonRow("Long 수락률",
                                  percent(longFormStat(longOnly)?.acceptanceRate),
                                  percent(longFormStat(longAndShort)?.acceptanceRate))
                }
            }
        }
        .navigationTitle("Long vs Long+Short")
    }

    /// Task 064: `hvc1 profile=1 tier=Main level=5.1` -> `hvc1 L5.1`. The full string is
    /// on the detail screen; this column is 90pt wide and the two facts that matter here
    /// are the codec and the level. Falls back to the raw string if it has no level, so
    /// an unparsed format is still shown rather than hidden.
    private func codecAndLevel(_ format: String?) -> String {
        guard let format, !format.isEmpty else { return "—" }
        let codec = format.split(separator: " ").first.map(String.init) ?? format
        guard let level = format
            .split(separator: " ")
            .first(where: { $0.hasPrefix("level=") })?
            .dropFirst("level=".count) else { return format }
        return "\(codec) L\(level)"
    }

    /// The long-form writer in a record: the one that never ran a crop.
    private func longFormStat(_ record: RecordingDiagnostics?) -> WriterAppendStats? {
        record?.writerStats?.first { $0.averageCropSeconds == 0 }
    }

    private func comparisonRow(_ label: String, _ left: String, _ right: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(left)
                .font(.caption.monospacedDigit())
                .frame(width: 90, alignment: .trailing)
            Text(right)
                .font(.caption.monospacedDigit().bold())
                .frame(width: 90, alignment: .trailing)
        }
    }

    private func fps(_ value: Float?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }

    private func fps(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    private func ms(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2fms", value)
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value * 100)
    }

    private func count(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value)"
    }

    private func format(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        return String(format: "%.1fs", seconds)
    }
}
