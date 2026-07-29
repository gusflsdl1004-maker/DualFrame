//
//  WriterAppendStats.swift
//  DualFrame
//

import Foundation

/// Task 059 items 1/2/4: how one writer actually behaved over a recording — how many
/// frames it was offered, how many it took, how many it refused, and how long its own
/// append call took on average.
///
/// Recorded in every configuration, not just Debug: the 36fps is a Release symptom, so
/// the numbers that explain it have to exist in Release.
///
/// Reading it: `notReady` high with `averageAppendSeconds` low means the writer is not
/// slow to accept a frame, it is refusing to accept one — i.e. the encoder behind it is
/// applying backpressure, and the frames are skipped rather than delayed. `notReady`
/// low with `averageAppendSeconds` high would mean the opposite: appends are being
/// accepted but each one costs too much.
nonisolated struct WriterAppendStats: Codable, Equatable, Identifiable {
    let outputName: String
    let attempts: Int
    let appended: Int
    let notReady: Int
    let averageAppendSeconds: TimeInterval

    var id: String { outputName }

    /// Share of offered frames this writer actually wrote.
    var acceptanceRate: Double {
        attempts > 0 ? Double(appended) / Double(attempts) : 0
    }

    var averageAppendMilliseconds: Double { averageAppendSeconds * 1000 }
}
