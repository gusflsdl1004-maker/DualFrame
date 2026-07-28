//
//  RecordingService.swift
//  DualFrame
//

import AVFoundation

/// Lifecycle states for a single recording.
/// `nonisolated` because it's compared from within `RecordingService`'s own actor context,
/// not the default main-actor isolation this project applies to unannotated types.
nonisolated enum RecordingState: Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case finished
    case failed
}

/// Owns the `AVAssetWriter` pipeline: creates the writer and inputs, appends sample
/// buffers forwarded from `CameraService`, finishes the file safely, and validates it
/// with `RecordingValidator` before reporting success.
/// No gallery saving, dual recording, or automatic recovery happens here.
actor RecordingService {
    private(set) var state: RecordingState = .idle
    private(set) var lastError: RecordingError?
    private(set) var lastValidationResult: RecordingValidationResult?
    private(set) var lastImportedRecord: VideoRecord?

    private let validator = RecordingValidator()
    private let libraryService: InternalVideoLibraryService

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var isSessionStarted = false

    init(libraryService: InternalVideoLibraryService) {
        self.libraryService = libraryService
    }

    @discardableResult
    func prepareRecording() async -> RecordingState {
        guard state == .idle || state == .finished || state == .failed else { return state }
        state = .preparing
        lastError = nil
        lastValidationResult = nil
        lastImportedRecord = nil

        do {
            try setUpWriter()
        } catch {
            lastError = .writerCreationFailed
            state = .failed
        }
        return state
    }

    @discardableResult
    func startRecording() async -> RecordingState {
        guard state == .preparing, assetWriter != nil else { return state }
        state = .recording
        return state
    }

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        await append(sampleBuffer, to: videoInput)
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        await append(sampleBuffer, to: audioInput)
    }

    /// Finishes writing and validates the resulting file.
    /// `expectsAudioTrack` should reflect whether microphone permission was granted —
    /// a missing audio track is only an error when audio was actually expected.
    @discardableResult
    func stopRecording(expectsAudioTrack: Bool) async -> RecordingState {
        guard state == .recording else { return state }
        state = .stopping

        guard let writer = assetWriter, isSessionStarted, let url = outputURL else {
            // Nothing was ever written (e.g. stopped before the first sample buffer arrived).
            lastError = .writeFailed
            state = .failed
            return state
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            lastError = .writeFailed
            state = .failed
            return state
        }

        let result = await validator.validate(fileURL: url, expectsAudioTrack: expectsAudioTrack)
        lastValidationResult = result

        guard result.isValid else {
            lastError = result.error ?? .validationFailed
            state = .failed
            return state
        }

        do {
            // Moves the file out of the temporary directory — nothing stays there once
            // a recording succeeds.
            lastImportedRecord = try await libraryService.importRecording(from: url, validation: result)
            state = .finished
        } catch {
            lastError = .unknown
            state = .failed
        }
        return state
    }

    /// The finished recording's permanent file URL in the internal library, if the last
    /// recording completed, validated, and was imported successfully.
    func outputFileURL() -> URL? {
        lastImportedRecord?.localURL
    }

    private func setUpWriter() throws {
        let url = Self.makeOutputURL()
        let writer = try AVAssetWriter(url: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080
        ]
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000
        ]
        let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioWriterInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoWriterInput) else { throw RecordingError.writerCreationFailed }
        writer.add(videoWriterInput)

        guard writer.canAdd(audioWriterInput) else { throw RecordingError.writerCreationFailed }
        writer.add(audioWriterInput)

        assetWriter = writer
        videoInput = videoWriterInput
        audioInput = audioWriterInput
        outputURL = url
        isSessionStarted = false
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) async {
        guard state == .recording, let writer = assetWriter, let input else { return }

        if !isSessionStarted {
            guard writer.startWriting() else {
                lastError = .writeFailed
                state = .failed
                return
            }
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: startTime)
            isSessionStarted = true
        }

        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)

        if writer.status == .failed {
            lastError = .writeFailed
            state = .failed
        }
    }

    private static func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
    }
}
