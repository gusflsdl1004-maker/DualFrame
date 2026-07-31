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
final class ShortGenerationCoordinator: NSObject, ObservableObject {
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
    /// The group being filled in, by id. The library badges on this rather than on a
    /// timestamp, for the same reason the attach does.
    @Published private(set) var activeGroupID: String?
    /// Task 074: set when the user taps the completion notification, so the UI can open
    /// the library on the short-form output that just finished. Cleared by the view once
    /// it has navigated, so a second tap is needed to navigate again.
    @Published var pendingNavigationGroupID: String?
    /// Task 075 item 5: shown in the banner, so the wait is attributable to the setting
    /// that caused it rather than looking like the app being slow.
    @Published private(set) var activeQuality: ShortGenerationQuality = .fast
    /// Task 074 P1: the completion banner dismisses itself after a moment. A success
    /// message that needs acknowledging is a chore — the notification already covers the
    /// case where the user is not looking.
    private var autoDismissTask: Task<Void, Never>?

    private let generationService = ShortGenerationService()
    private let libraryService: InternalVideoLibraryService
    private let groupService: RecordingGroupService
    private let diagnosticsService: RecordingDiagnosticsService
    private let cropBackendSettingsService = CropBackendSettingsService()
    private let encoderSettingsService = VideoEncoderSettingsService()
    /// Task 074 P2: read per job, so a change applies to the next generation.
    private let qualitySettingsService = ShortGenerationQualitySettingsService()

    private var currentTask: Task<Void, Never>?
    /// Task 072 P0-4: when the current job began, so the remaining time can be
    /// extrapolated from progress actually achieved rather than guessed from file size.
    private var jobStartedAt: Date?
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
        /// Task 072 P0-1: the group and diagnostics records this job belongs to, by
        /// **id**. Task 070 looked them up by comparing `Date`s, which silently never
        /// matched — both stores encode with `.iso8601`, truncating to whole seconds, so
        /// a reloaded date never equalled the in-memory one. The result was a generated
        /// short-form file that existed on disk and in the library but was attached to
        /// no group, so it never appeared as an export target.
        let groupID: String?
        let diagnosticsID: String?
    }

    init(
        libraryService: InternalVideoLibraryService,
        groupService: RecordingGroupService = RecordingGroupService(),
        diagnosticsService: RecordingDiagnosticsService = RecordingDiagnosticsService()
    ) {
        self.libraryService = libraryService
        self.groupService = groupService
        self.diagnosticsService = diagnosticsService
        super.init()
        // Task 074: needed for the tap to reach us at all — without a delegate, tapping
        // a delivered notification just foregrounds the app and nothing happens.
        UNUserNotificationCenter.current().delegate = self
    }

    /// True while a job for `sessionID` is running — drives the library's "생성 중" badge.
    func isGenerating(sessionID: UUID?) -> Bool {
        guard let sessionID, sessionID == activeSessionID else { return false }
        return state.isGenerating
    }

    /// Task 072 P0-1: matched by group **id**. The previous version compared
    /// `RecordingGroup.createdAt` against an in-memory `Date`, which never matched once
    /// the group had been through JSON — so the "생성 중" badge never appeared at all.
    func isGenerating(forGroupID groupID: String) -> Bool {
        guard let activeGroupID, activeGroupID == groupID else { return false }
        return state.isGenerating
    }

    /// Requirement 1/2: returns immediately. The caller's recording flow is finished the
    /// moment this is called; everything after happens here.
    func start(_ request: Request) {
        guard currentTask == nil else { return }
        lastRequest = request
        activeSessionID = request.sessionID
        activeRecordingStartTime = request.recordingStartTime
        activeGroupID = request.groupID
        activeQuality = qualitySettingsService.load().quality
        state = .generating(progress: 0, stage: .analyzing)
        jobStartedAt = Date()
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
        activeGroupID = nil
    }

    // MARK: - Private

    private func run(_ request: Request) async {
        let profile = OutputProfile.shortForm
        let targetSize = CGSize(width: profile.resolution.width, height: profile.resolution.height)
        let configuration = CropConfiguration(targetSize: targetSize, strategy: .center)
        let backend = cropBackendSettingsService.load().backend
        // Task 074 P2: `.fast` halves the frames the encoder has to produce, which is
        // the single largest lever available on generation time short of changing the
        // architecture again.
        let quality = qualitySettingsService.load().quality
        let outputFPS = quality.outputFPS(sourceFPS: request.fps)
        let codec = encoderSettingsService.load().codec.resolvedCodec(
            width: profile.resolution.width,
            height: profile.resolution.height,
            fps: outputFPS.rawValue
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
                fps: outputFPS,
                codec: codec,
                backend: backend,
                quality: quality,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.state.isGenerating else { return }
                        self.state = .generating(
                            progress: progress,
                            stage: .converting,
                            remainingSeconds: self.remainingEstimate(progress: progress)
                        )
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

    /// Extrapolates from elapsed time and progress so far.
    ///
    /// Suppressed below 5% because an estimate from the opening frames swings wildly —
    /// reader/writer setup is front-loaded, so the early rate is not representative, and
    /// a countdown that jumps is worse than no countdown.
    private func remainingEstimate(progress: Double) -> Double? {
        guard let jobStartedAt, progress > 0.05 else { return nil }
        let elapsed = Date().timeIntervalSince(jobStartedAt)
        guard elapsed > 0 else { return nil }
        return elapsed / progress - elapsed
    }

    private func complete(request: Request, outputURL: URL, metrics: ShortGenerationMetrics) async {
        // P0-9: validation + library import is a distinct, visible phase — on a 3GB
        // source it is not instantaneous, and leaving the banner at "생성 중 100%"
        // through it looks like a hang.
        state = .generating(progress: 1, stage: .saving)
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
            scheduleAutoDismiss()
            await notify(
                title: "쇼츠 영상 생성이 완료되었습니다",
                body: "라이브러리에서 확인할 수 있습니다.",
                groupID: request.groupID
            )
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
        guard let groupID = request.groupID else { return }
        let groups = await groupService.loadAll()
        guard let existing = groups.first(where: { $0.id == groupID }) else { return }
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
        guard let diagnosticsID = request.diagnosticsID else { return }
        let existing = await diagnosticsService.loadAll()
        guard let base = existing.first(where: { $0.id == diagnosticsID }) else { return }
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
            secondPreviewEnabled: base.secondPreviewEnabled,
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
    /// Task 074 P1: clears a success banner on its own. Only success — a failure or a
    /// cancellation stays until acknowledged, because both offer a 다시 생성 action the
    /// user would otherwise never see.
    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard let self, self.state == .finished else { return }
            self.state = .idle
            self.activeSessionID = nil
            self.activeRecordingStartTime = nil
            self.activeGroupID = nil
        }
    }

    private func notify(title: String, body: String, groupID: String? = nil) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Carried so the tap knows which recording to open. By id, not by timestamp —
        // the same rule the Task 072 fix established.
        if let groupID { content.userInfo = ["groupID": groupID] }
        try? await center.add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}


// MARK: - Notification tap (Task 074)

extension ShortGenerationCoordinator: UNUserNotificationCenterDelegate {
    /// Shows the banner even when the app is already frontmost. Without this iOS
    /// suppresses it, and a user watching the screen would get no confirmation at all
    /// on the one path where the in-app banner has already auto-dismissed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// The tap. Publishes the group id; the camera screen opens the library on it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let groupID = response.notification.request.content.userInfo["groupID"] as? String
        await MainActor.run { self.pendingNavigationGroupID = groupID }
    }
}
