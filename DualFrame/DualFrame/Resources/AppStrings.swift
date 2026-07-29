//
//  AppStrings.swift
//  DualFrame
//

import Foundation

/// Task 038: centralizes the strings that are either shown in more than one screen
/// (so a future wording change or translation only has to happen once) or were
/// explicitly called out for a specific mapping. This is deliberately not an attempt
/// to route every string in the app through one file — most screens keep their
/// Korean text as plain string literals, since duplicating a hundred one-off labels
/// into an enum would add indirection without adding any real reuse.
///
/// This is the starting point for the "Localizable 구조" this task asks for: today it
/// only holds Korean values (이번에는 한국어만 적용), but grouping the shared/reused
/// strings here — rather than leaving them duplicated across files — is what makes it
/// straightforward to convert into a proper `String Catalog`/`Localizable.strings`
/// lookup later without having to first go hunt every call site down again.
nonisolated enum AppStrings {
    /// Task 038 requirement 3's exact mapping. `RecordingViewModel.statusText`/
    /// `displayStatusText` are the only readers of these today.
    enum RecordingStatus {
        static let ready = "준비 완료"
        static let preparing = "준비 중"
        static let recording = "녹화 중"
        static let stopping = "정지 중"
        static let success = "녹화 완료"
        static let failed = "녹화 실패"
        static let paused = "일시정지"
    }

    enum Camera {
        static let startRecording = "녹화 시작"
        static let stopRecording = "녹화 중지"
    }

    /// Was duplicated as an identical `switch` in three separate files
    /// (`CameraPreviewView`/`RecordingSettingsSummaryView`/`RecordingDebugView`) before
    /// this task — centralized here instead of translating each copy separately.
    static func orientationLabel(_ orientation: RecordingOrientation) -> String {
        switch orientation {
        case .portrait: "세로"
        case .portraitUpsideDown: "세로 (뒤집힘)"
        case .landscapeLeft: "가로 (왼쪽)"
        case .landscapeRight: "가로 (오른쪽)"
        }
    }
}
