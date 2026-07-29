//
//  CropBackend.swift
//  DualFrame
//

import Foundation

/// Which implementation performs the short-form crop.
///
/// Task 068: both exist at once and are switchable at runtime, because the two things
/// that could go wrong with the VideoToolbox path — colour/range shift and a different
/// scaler's sharpness — are **visual** judgements that a build cannot make. A setting
/// means a bad result is one toggle away from being undone, not a rebuild
/// (CLAUDE.md rules 44 and 49-51).
///
/// The measured cost this exists to attack: Long Only runs 16.815 ms/frame (59.47fps)
/// and Long + Short runs 19.365 ms/frame (51.64fps), so the short-form path costs
/// 2.550 ms/frame. Removing all of it lands at 59.47fps, which is the ceiling — 60fps
/// is not reachable even with a free crop.
nonisolated enum CropBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The original path, unchanged since Task 021. CoreImage always works in a linear
    /// RGB space, so a YCbCr capture buffer is converted to RGB on input and back out
    /// to the 32BGRA destination — and the encoder then converts that BGRA back to
    /// YCbCr. Two conversions that cancel, around an 8.29 MB intermediate.
    case coreImage
    /// `VTPixelTransferSession`, which stays in YCbCr end to end. The destination pool
    /// matches the source's pixel format, so the intermediate is 3.11 MB instead of
    /// 8.29 MB (0.19 GB/s vs 0.50 GB/s at 60fps) and the encoder receives a buffer it
    /// can consume without converting.
    case videoToolbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coreImage: "CoreImage (기존)"
        case .videoToolbox: "VideoToolbox"
        }
    }

    var shortTitle: String {
        switch self {
        case .coreImage: "CoreImage"
        case .videoToolbox: "VT"
        }
    }

    var detail: String {
        switch self {
        case .coreImage: "검증된 기존 구현. YCbCr→RGB→BGRA 변환을 거칩니다."
        case .videoToolbox: "YCbCr을 유지해 색공간 변환과 중간 버퍼 대역폭을 줄입니다. 색·선명도를 눈으로 확인하세요."
        }
    }
}

/// Persisted wrapper, matching every other settings model in this project.
nonisolated struct CropBackendSettings: Codable, Equatable, Sendable {
    var backend: CropBackend

    /// Defaults to the existing implementation. The new path is opt-in until it has
    /// been checked on a real device — recording stability outranks the frame rate it
    /// is trying to buy (CLAUDE.md rules 1-3).
    static let `default` = CropBackendSettings(backend: .coreImage)
}
