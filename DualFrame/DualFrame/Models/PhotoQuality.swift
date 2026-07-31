//
//  PhotoQuality.swift
//  DualFrame
//

import AVFoundation
import Foundation

/// Task 093 P1-1: how much the still capture should spend on quality.
///
/// Maps onto two real `AVCapturePhotoSettings` levers — the codec and
/// `photoQualityPrioritization` — plus, at the top setting only, an explicit
/// `maxPhotoDimensions`. Nothing here is decorative; see `CameraService.capturePhoto`.
nonisolated enum PhotoQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case high
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "표준"
        case .high: "고화질"
        case .maximum: "최고화질"
        }
    }

    var detail: String {
        switch self {
        case .standard: "JPEG로 가장 빠르게 저장합니다. 용량이 가장 작습니다."
        case .high: "기기가 지원하면 HEIF로 저장합니다. 대부분의 경우 권장합니다."
        case .maximum: "지원하는 가장 높은 해상도와 품질로 저장합니다. 용량이 커지고 저장이 조금 느려집니다."
        }
    }

    /// `.speed` finishes the capture as soon as it can; `.quality` lets the encoder use
    /// multi-frame processing. The output's `maxPhotoQualityPrioritization` has to be at
    /// least this, or `capturePhoto` raises — see `CameraService.configure()`.
    var prioritization: AVCapturePhotoOutput.QualityPrioritization {
        switch self {
        case .standard: .speed
        case .high: .balanced
        case .maximum: .quality
        }
    }

    /// Task 093 P1-4: HEIF where the device offers it, JPEG otherwise. 표준 asks for JPEG
    /// outright — the point of that setting is the smallest, fastest, most universally
    /// readable file, and HEIF is none of those things.
    var prefersHEIF: Bool { self != .standard }

    /// Task 093 P1-5: only the top setting asks for the largest still the hardware can
    /// produce. The other two take the format's default, which is what kept Task 092's
    /// crash from being reachable at all.
    var requestsMaximumDimensions: Bool { self == .maximum }
}

nonisolated struct PhotoQualitySettings: Codable, Equatable, Sendable {
    var quality: PhotoQuality

    /// 고화질 by default — the setting a general user should be on, per the spec.
    static let `default` = PhotoQualitySettings(quality: .high)
}

nonisolated struct PhotoQualitySettingsService {
    private let defaults: UserDefaults
    private let key = "com.dualframe.photoQualitySettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PhotoQualitySettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(PhotoQualitySettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: PhotoQualitySettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
