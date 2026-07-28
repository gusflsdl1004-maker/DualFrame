//
//  VideoRecord.swift
//  DualFrame
//

import Foundation
import CoreGraphics

/// A single recording stored in the app's internal video library.
/// `nonisolated` because it's passed between the library actor and main-actor view models,
/// not the default main-actor isolation this project applies to unannotated types.
nonisolated struct VideoRecord: Identifiable, Equatable {
    let id: String
    let filename: String
    let createdAt: Date
    let duration: TimeInterval
    let resolution: CGSize
    let fileSize: Int64
    let localURL: URL
    /// Task 024: which recording session produced this file, and which output
    /// (long-form/short-form/single) it is. `nil` for any recording made before Task
    /// 024 existed — see `InternalVideoLibraryService.loadRecordingGroups(groupService:)`
    /// for how those fall back to the Task 023 time/aspect-ratio heuristic instead.
    let sessionID: UUID?
    let outputProfile: OutputProfile?
}
