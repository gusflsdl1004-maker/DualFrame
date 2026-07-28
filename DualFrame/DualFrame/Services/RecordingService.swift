//
//  RecordingService.swift
//  DualFrame
//

import AVFoundation

/// Lifecycle states for a single recording.
enum RecordingState: Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case finished
    case failed
}

/// Foundation for the recording engine.
///
/// This owns the recording state machine and will own the `AVAssetWriter` pipeline
/// once a capture output feeds it sample buffers in a later task. It does not record,
/// write, or save any video yet — see the TODOs below for what each stage will need.
actor RecordingService {
    private(set) var state: RecordingState = .idle

    /// Will be configured (output URL, video/audio inputs) once real writing is implemented.
    private var assetWriter: AVAssetWriter?

    @discardableResult
    func prepareRecording() async -> RecordingState {
        state = .preparing
        // TODO: Create the AVAssetWriter with an output file URL and add
        // AVAssetWriterInput(s) once the capture pipeline (sample buffer output
        // from CameraService) exists.
        state = .idle
        return state
    }

    @discardableResult
    func startRecording() async -> RecordingState {
        guard state != .recording else { return state }
        state = .recording
        // TODO: Call assetWriter.startWriting() and startSession(atSourceTime:)
        // when the first sample buffer arrives.
        return state
    }

    @discardableResult
    func stopRecording() async -> RecordingState {
        guard state == .recording else { return state }
        state = .stopping
        // TODO: Call assetWriter.finishWriting and report the output file URL.
        state = .finished
        return state
    }
}
