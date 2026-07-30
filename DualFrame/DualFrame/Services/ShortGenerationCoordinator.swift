//
//  ShortGenerationCoordinator.swift
//  DualFrame
//

import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Owns short-form generation for the whole app, independently of any screen.
///
/// Task 070. In Task 069 generation was awaited inside
/// `RecordingViewModel.stopRecording()`, which meant the recording flow did not finish
/// until the short-form file existed — roughly 20 seconds of the user staring at a
/// progress bar. That wait is now gone: recording completes immediately and generation
/// continues here.
///
/// Living outside `RecordingViewModel` is what makes requirement 3 possible. A view
/// model tied to the camera screen cannot keep a job alive while the user browses the
/// library or changes settings; this object is created once at the app root and outlives
/// every screen.
///
/// **It can never endanger a recording.** It is only ever handed a long-form file that
/// has already been written, validated and imported. Everything it does is derived work
/// on a copy of that URL (CLAUDE.md rule 1).
@MainActor
final class ShortGenerationCoordinator: ObservableObject {
    /// What the UI shows: the progress card on the camera screen, and the library badge.
    @Published private(set) var state: ShortGenerationState = .idle
    /// The record the in-flight (or just-finished) short-form output belongs to, so the
    /// library can badge the right row rather than badging everything.
    @Published private(set) var activeSessionID: UUID?
    /// The recording start time of the job in flight. `RecordingGroup` has no
    /// `sessionID` field — it is keyed by `createdAt`, which equals the recording's
    /// start time — so this is what lets the library badge exactly one row instead of
    /// all of them.
    @Published private(set) var activeRecordingStartTime: Date?

    private let generationService = ShortGenerationService()
    private let libraryService: InternalVideoLibraryService
    private let groupService: RecordingGroupService
    private let diagnosticsService: RecordingDiagnosticsService
    private let cropBackendSettingsService = CropBackendSettingsService()
    private let encoderSettingsService = VideoEncoderSettingsService()

    private var currentTask: Task<Void, Never>?
    /// Everything needed to re-run a failed or cancelled job without the camera screen.
    private var lastRequest: Request?

    /// Requirement 9. Without this, iOS suspends the app seconds after it leaves the
    /// foreground and the generation stops mid-file. The assertion buys the ~30 seconds
    /// that a typical generation needs; it is not a guarantee, which is why the failure
    /// path below still has to be safe.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// A generation job, kept whole so retry needs nothing from the caller.
    struct Request {
        let sourceURL: URL
        let sessionID: UUID
        let sessionMetadata: RecordingSessionMetadata
        let fps: RecordingFPS
        let recordingStartTime: Date
        let recordingDuration: TimeInterval
    }

    init(
        libraryService: InternalVideoLibraryService,
        groupService: RecordingGroupService = RecordingGroupService(),
        diagnosticsService: RecordingDiagnosticsService = RecordingDiagnosticsService()
    ) {
        self.libraryService = libraryService
        self.groupService = groupService
        self.diagnosticsService = diagnosticsService
    }

    /// True while a job for `sessionID` is running — drives the library's "생성 중" badge.
    func isGenerating(sessionID: UUID?) -> Bool {
        guard let sessionID, sessionID == activeSessionID else { return false }
        return state.isGenerating
    }

    /// Requirement 5: the library keys rows by `RecordingGroup.createdAt`, so the badge
    /// is matched on that rather than on a session id the group does not carry.
    func isGenerating(forRecordingStartedAt createdAt: Date) -> Bool {
        guard let activeRecordingStartTime, activeRecordingStartTime == createdAt else { return false }
        return state.isGenerating
    }

    /// Requirement 1/2: returns immediately. The caller's recording flow is finished the
    /// moment this is called; everything after happens here.
    func start(_ request: Request) {
        guard currentTask == nil else { return }
        lastRequest = request
        activeSessionID = request.sessionID
        activeRecordingStartTime = request.recordingStartTime
        state = .generating(progress: 0)
        beginBackgroundAssertion()

        currentTask = Task { [weak self] in
            await self?.run(request)
            self?.currentTask = nil
            self?.endBackgroundAssertion()
        }
    }

    func cancel() {
        currentTask?.cancel()
    }

    /// Requirement: re-runnable after a failure or cancellation, from anywhere — the
    /// camera screen is not involved.
    func retry() {
        guard currentTask == nil, let lastRequest else { return }
        start(lastRequest)
    }

    /// Clears a finished/failed/cancelled card. Refuses while a job is running so it
    /// cannot be used to hide one.
    func dismissResult() {
        guard !state.isGenerating else { return }
        state = .idle
        activeSessionID = nil
        activeRecordingStartTime = nil
    }

    // MARK: - Private

    private func run(_ request: Request) async {
        let profile = OutputProfile.shortForm
        let targetSize = CGSize(width: profile.resolution.width, height: profile.resolution.height)
        let configuration = CropConfiguration(targetSize: targetSize, strategy: .center)
        let backend = cropBackendSettingsService.load().backend
        let codec = encoderSettingsService.load().codec.resolvedCodec(
            width: profile.resolution.width,
            height: profile.resolution.height,
            fps: request.fps.rawValue
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("short-\(UUID().uuidString).mov")

        // Re-opened for the duration of the job so the generated file is imported while
        // the session is registered and therefore carries the recording's `sessionID` —
        // the identifier `RecordingGroup` is built from (CLAUDE.md rules 59-62).
        // `RecordingViewModel` has already closed its own session by now.
        await libraryService.beginSession(request.sessionMetadata)
        defer { Task { await libraryService.endSession(request.sessionID) } }

        do {
            let metrics = try await generationService.generate(
                from: request.sourceURL,
                to: outputURL,
                configuration: configuration,
                fps: request.fps,
                codec: codec,
                backend: backend,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.state.isGenerating else { return }
                        self.state = .generating(progress: progress)
                    }
                }
            )
            await complete(request: request, outputURL: outputURL, metrics: metrics)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            let isCancelled = (error as? ShortGenerationError) == .cancelled || error is CancellationError
            state = isCancelled
                ? .cancelled
                : .failed(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            // Deliberately no notification on cancel — the user did it and is looking at
            // the app. A failure is worth telling them about even if they navigated away.
            if !isCancelled {
                await notify(title: "쇼츠 생성에 실패했습니다", body: "원본 영상은 그대로 저장되어 있습니다.")
            }
        }
    }

    private func complete(request: Request, outputURL: URL, metrics: ShortGenerationMetrics) async {
        let validation = await RecordingValidator().validate(fileURL: outputURL, expectsAudioTrack: false)
        guard validation.isValid else {
            try? FileManager.default.removeItem(at: outputURL)
            state = .failed(reason: validation.error?.message ?? "검증 실패")
            await notify(title: "쇼츠 생성에 실패했습니다", body: "원본 영상은 그대로 저장되어 있습니다.")
            return
        }

        do {
            let record = try await libraryService.importRecording(from: outputURL, validation: validation)
            // Requirement 6: the group flips from "long only" to including the
            // short-form member, which is what turns the library row from "생성 중" into
            // a ready short-form output.
            await attachShortToGroup(request: request, shortRecordID: record.id)
            await saveDiagnostics(request: request, metrics: metrics)
            state = .finished
            await notify(title: "쇼츠 영상 생성이 완료되었습니다", body: "라이브러리에서 확인할 수 있습니다.")
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            state = .failed(reason: "라이브러리 저장 실패")
            await notify(title: "쇼츠 생성에 실패했습니다", body: "원본 영상은 그대로 저장되어 있습니다.")
        }
    }

    /// Updates the group written at stop time so it now references the short-form record.
    ///
    /// Task 070 fixes the ordering Task 069 introduced: the group used to be written only
    /// *after* generation, so an app killed mid-generation left the long-form recording
    /// with no group at all. It is now written immediately at stop with the long-form
    /// member, and this fills in the short-form member afterwards.
    private func attachShortToGroup(request: Request, shortRecordID: String) async {
        let groups = await groupService.loadAll()
        guard let existing = groups.first(where: { $0.createdAt == request.recordingStartTime }) else { return }
        let updated = RecordingGroup(
            id: existing.id,
            createdAt: existing.createdAt,
            recordingMode: existing.recordingMode,
            longRecording: existing.longRecording,
            shortRecording: .succeeded(videoRecordID: shortRecordID),
            duration: existing.duration,
            outputMode: existing.outputMode
        )
        await groupService.save(updated)
    }

    /// Generation now outlives `RecordingViewModel`'s diagnostics write, so its metrics
    /// are saved here as their own record rather than being lost.
    private func saveDiagnostics(request: Request, metrics: ShortGenerationMetrics) async {
        let existing = await diagnosticsService.loadAll()
        guard let base = existing.first(where: { $0.recordingStartTime == request.recordingStartTime }) else { return }
        let updated = RecordingDiagnostics(
            id: base.id,
            recordingStartTime: base.recordingStartTime,
            recordingEndTime: base.recordingEndTime,
            recordingDuration: base.recordingDuration,
            resolution: base.resolution,
            fps: base.fps,
            averageWriteLatency: base.averageWriteLatency,
            droppedVideoFrames: base.droppedVideoFrames,
            droppedAudioBuffers: base.droppedAudioBuffers,
            peakMemoryUsageBytes: base.peakMemoryUsageBytes,
            availableStorageBytes: base.availableStorageBytes,
            checkpointCount: base.checkpointCount,
            recoveryStatus: base.recoveryStatus,
            deliveredVideoFrames: base.deliveredVideoFrames,
            droppedBeforeConsumer: base.droppedBeforeConsumer,
            savedNominalFrameRate: base.savedNominalFrameRate,
            writerStats: base.writerStats,
            droppedFrameReasons: base.droppedFrameReasons,
            lateFrameHandling: base.lateFrameHandling,
            videoCodecPreference: base.videoCodecPreference,
            keyFrameIntervalSeconds: base.keyFrameIntervalSeconds,
            bitratePreset: base.bitratePreset,
            savedVideoFormat: base.savedVideoFormat,
            encoderDecisions: base.encoderDecisions,
            savedVideoFormatsByProfile: base.savedVideoFormatsByProfile,
            savedFrameRatesByProfile: base.savedFrameRatesByProfile,
            thermalStateAtStart: base.thermalStateAtStart,
            peakThermalState: base.peakThermalState,
            thermalStateAtEnd: base.thermalStateAtEnd,
            dropSamples: base.dropSamples,
            dropAttachmentKeys: base.dropAttachmentKeys,
            cropBackend: base.cropBackend,
            shortGeneration: metrics
        )
        await diagnosticsService.save(updated)
    }

    // MARK: - Background assertion (requirement 9)

    private func beginBackgroundAssertion() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ShortGeneration") { [weak self] in
            // iOS is out of patience. Cancel cooperatively so the partial file is
            // deleted rather than left behind, and end the assertion — being killed
            // while holding it is worse than stopping cleanly.
            Task { @MainActor in
                self?.cancel()
                self?.endBackgroundAssertion()
            }
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Notification (requirement 4)

    /// Fire-and-forget. Permission is requested on first use rather than at launch —
    /// asking before the user has ever recorded anything has no context.
    private func notify(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await center.add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
