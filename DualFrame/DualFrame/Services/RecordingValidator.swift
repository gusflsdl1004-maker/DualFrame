//
//  RecordingValidator.swift
//  DualFrame
//

import AVFoundation

/// Errors that can occur while creating or validating a recording.
/// `nonisolated` because it's read from within `RecordingService`'s own actor context,
/// not the default main-actor isolation this project applies to unannotated types.
nonisolated enum RecordingError: Error, Equatable {
    case writerCreationFailed
    case invalidOutputFile
    case emptyRecording
    case writeFailed
    case audioTrackMissing
    case videoTrackMissing
    case validationFailed
    case unknown

    var message: String {
        switch self {
        case .writerCreationFailed: "Could not create the recording file."
        case .invalidOutputFile: "The recorded file could not be found."
        case .emptyRecording: "The recording is empty."
        case .writeFailed: "Writing the recording failed."
        case .audioTrackMissing: "The recording is missing its audio track."
        case .videoTrackMissing: "The recording is missing its video track."
        case .validationFailed: "The recording could not be validated."
        case .unknown: "An unknown recording error occurred."
        }
    }
}

/// The measurements and outcome of validating a recorded file.
nonisolated struct RecordingValidationResult: Equatable {
    let fileSize: Int64
    let duration: TimeInterval
    let resolution: CGSize?
    let hasVideoTrack: Bool
    let hasAudioTrack: Bool
    let error: RecordingError?

    var isValid: Bool { error == nil }
}

/// Confirms a recorded file is a real, playable video before any later feature
/// (export, gallery save) is allowed to touch it.
nonisolated struct RecordingValidator {
    func validate(fileURL: URL, expectsAudioTrack: Bool) async -> RecordingValidationResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return RecordingValidationResult(
                fileSize: 0,
                duration: 0,
                resolution: nil,
                hasVideoTrack: false,
                hasAudioTrack: false,
                error: .invalidOutputFile
            )
        }

        let fileSize = currentFileSize(at: fileURL)

        let asset = AVURLAsset(url: fileURL)
        do {
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.load(.tracks)
            let videoTrack = tracks.first { $0.mediaType == .video }
            let audioTrack = tracks.first { $0.mediaType == .audio }
            let resolution = try await videoTrack?.load(.naturalSize)

            let error = resolveError(
                fileSize: fileSize,
                duration: duration,
                hasVideoTrack: videoTrack != nil,
                hasAudioTrack: audioTrack != nil,
                expectsAudioTrack: expectsAudioTrack
            )

            return RecordingValidationResult(
                fileSize: fileSize,
                duration: duration,
                resolution: resolution,
                hasVideoTrack: videoTrack != nil,
                hasAudioTrack: audioTrack != nil,
                error: error
            )
        } catch {
            return RecordingValidationResult(
                fileSize: fileSize,
                duration: 0,
                resolution: nil,
                hasVideoTrack: false,
                hasAudioTrack: false,
                error: .validationFailed
            )
        }
    }

    private func currentFileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return 0
        }
        return size
    }

    private func resolveError(
        fileSize: Int64,
        duration: TimeInterval,
        hasVideoTrack: Bool,
        hasAudioTrack: Bool,
        expectsAudioTrack: Bool
    ) -> RecordingError? {
        if fileSize <= 0 || duration <= 0 {
            return .emptyRecording
        }
        if !hasVideoTrack {
            return .videoTrackMissing
        }
        if expectsAudioTrack, !hasAudioTrack {
            return .audioTrackMissing
        }
        return nil
    }
}
