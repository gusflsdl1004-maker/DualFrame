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

    /// Newest recording that ran a single writer.
    private var longOnly: RecordingDiagnostics? {
        sessions.first { ($0.writerStats?.count ?? 0) == 1 }
    }

    /// Newest recording that ran both writers.
    private var longAndShort: RecordingDiagnostics? {
        sessions.first { ($0.writerStats?.count ?? 0) >= 2 }
    }

    var body: some View {
        Form {
            if longOnly == nil || longAndShort == nil {
                Section {
                    ContentUnavailableView(
                        "비교할 기록이 부족합니다",
                        systemImage: "square.split.2x1",
                        description: Text("Long만 저장과 Long + Short 저장으로 각각 한 번씩 녹화하면 여기서 비교됩니다.")
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
