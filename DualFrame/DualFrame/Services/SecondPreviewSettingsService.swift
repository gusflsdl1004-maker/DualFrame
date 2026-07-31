//
//  SecondPreviewSettingsService.swift
//  DualFrame
//

import Foundation

/// Whether the short-form preview layer is attached to the capture session.
///
/// Task 077: this exists as a **switch** because the measurement that motivates it is
/// an A/B, and this project has been burned once by hardcoding one side of an untested
/// hypothesis — Task 055 pinned `alwaysDiscardsLateVideoFrames` to one value and every
/// measurement for the next eight tasks was taken on that side, so no comparison existed
/// at all. A toggle plus a record of which side produced each run is what makes the
/// answer attributable.
///
/// What is actually under test: the second preview layer needs its own
/// `AVCaptureConnection` from the video input port (Task 076). That connection is a real
/// consumer of the capture pipeline, unlike the layer itself — which is why the
/// reported rise in `FrameWasLate` and `OutOfBuffers` after it started working is a
/// plausible consequence rather than a coincidence.
/// Task 077 (revised): a three-way ablation, not an on/off.
///
/// One/two previews alone cannot separate three costs that all arrived together. This
/// does:
///
/// - `.single` → baseline. One layer, one connection, one full-screen pane.
/// - `.stacked` → the shipped structure. Two layers, two connections, two panes.
/// - `.stackedNoConnection` → **the discriminator.** Identical layout, second layer
///   allocated and laid out, but no second `AVCaptureConnection`, so it renders black.
///
/// `.stacked` minus `.stackedNoConnection` is the connection's cost — the capture-side
/// consumer. `.stackedNoConnection` minus `.single` is the layer and layout cost — the
/// display side. If the first difference is the whole regression, the fix is to drop the
/// connection during recording and keep the layout; if the second is, the layout itself
/// is the problem and no connection trick saves it.
nonisolated enum PreviewExperimentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case single
    case stacked
    case stackedNoConnection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "① 프리뷰 1개 (기준)"
        case .stacked: "② 프리뷰 2개 (현재)"
        case .stackedNoConnection: "③ 2개 · 연결 없음"
        }
    }

    var detail: String {
        switch self {
        case .single: "전체 화면 프리뷰 하나. 두 번째 레이어도 연결도 없습니다."
        case .stacked: "상단 세로 + 하단 가로. 레이어 2개, 캡처 연결 2개."
        case .stackedNoConnection: "레이아웃은 ②와 동일하지만 두 번째 연결이 없어 상단이 검게 보입니다. 정상이며, 연결 비용만 분리하기 위한 조건입니다."
        }
    }

    /// Whether the stacked layout is used at all.
    var usesStackedLayout: Bool { self != .single }
    /// Whether the second layer gets a capture connection.
    var connectsSecondPreview: Bool { self == .stacked }
}

nonisolated struct SecondPreviewSettings: Codable, Equatable, Sendable {
    /// Kept so records and settings written by the first version still decode.
    var isEnabled: Bool
    var mode: PreviewExperimentMode?
    /// Task 080 item 6: paint the short pane's preview layer red instead of black.
    ///
    /// This is the one observation that splits "the layer is not being drawn" from "the
    /// layer is drawn but empty", and those two have nothing in common as bugs. Optional
    /// so settings written before Task 080 still decode.
    var diagnosticProbe: Bool?

    var resolvedMode: PreviewExperimentMode {
        mode ?? (isEnabled ? .stacked : .single)
    }

    var showsDiagnosticProbe: Bool { diagnosticProbe ?? false }

    /// Defaults to the shipped structure — turning it off by default would silently
    /// change what the user sees before the measurement says it should.
    static let `default` = SecondPreviewSettings(isEnabled: true, mode: .stacked)
}

nonisolated struct SecondPreviewSettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.secondPreviewSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SecondPreviewSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(SecondPreviewSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: SecondPreviewSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
