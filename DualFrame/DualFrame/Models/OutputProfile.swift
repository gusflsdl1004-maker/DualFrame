//
//  OutputProfile.swift
//  DualFrame
//

import Foundation

/// A recorded video's pixel dimensions. A small `Codable`/`Equatable` value so
/// `OutputProfile` can describe a resolution without depending on AVFoundation.
nonisolated struct OutputResolution: Codable, Equatable, Hashable {
    let width: Int
    let height: Int
}

/// The intended shape of one recorded output. `.widescreen` matches today's single
/// recording pipeline; `.vertical` is the future short-form output.
nonisolated enum OutputAspectRatio: String, Codable, Equatable, Hashable {
    case widescreen
    case vertical

    var title: String {
        switch self {
        case .widescreen: "16:9"
        case .vertical: "9:16"
        }
    }
}

/// Describes one output a recording session could produce: its resolution, frame
/// rate, aspect ratio, and a display name. Purely a data model — nothing here
/// creates an `AVAssetWriter` or touches capture hardware (requirement 3).
///
/// `DualRecordingCoordinator` maps a `RecordingMode` to a list of these; today only
/// `.longForm` is ever actually recorded (see `RecordingService`'s single
/// `WriterContext`).
nonisolated struct OutputProfile: Codable, Equatable, Hashable, Identifiable {
    let outputName: String
    let resolution: OutputResolution
    let fps: RecordingFPS
    let aspectRatio: OutputAspectRatio

    var id: String { outputName }

    /// The long-form (16:9) output profile — what the single recording pipeline
    /// produces today (requirement 4).
    static let longForm = OutputProfile(
        outputName: "Long-form",
        resolution: OutputResolution(width: 1920, height: 1080),
        fps: .fps30,
        aspectRatio: .widescreen
    )

    /// The short-form (9:16) output profile a future dual recording pipeline would
    /// add alongside `.longForm` (requirement 5). Not yet produced by anything.
    static let shortForm = OutputProfile(
        outputName: "Short-form",
        resolution: OutputResolution(width: 1080, height: 1920),
        fps: .fps30,
        aspectRatio: .vertical
    )
}
