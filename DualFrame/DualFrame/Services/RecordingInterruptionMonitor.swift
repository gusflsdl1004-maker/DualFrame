//
//  RecordingInterruptionMonitor.swift
//  DualFrame
//

import AVFoundation
import Combine
import UIKit

/// Where an interruption came from, as best `AVFoundation`/`UIKit` notifications let
/// us tell. Some of these are not reliably distinguishable from public APIs — see the
/// mapping notes on `RecordingInterruptionMonitor.interruptionSource(from:)`.
nonisolated enum InterruptionSource: Equatable {
    case phoneCall
    case siri
    case lockScreen
    case appBackground
    case cameraInUse
    case audioRouteChange
    case unknown

    var title: String {
        switch self {
        case .phoneCall: "Phone Call"
        case .siri: "Siri"
        case .lockScreen: "Lock Screen"
        case .appBackground: "App Backgrounded"
        case .cameraInUse: "Camera In Use by Another App"
        case .audioRouteChange: "Audio Route Change"
        case .unknown: "Unknown Interruption"
        }
    }
}

/// Detection-only status for display — this never triggers handling or recovery by
/// itself (rule 37: detection, handling, and recovery are kept distinct).
nonisolated enum InterruptionStatus: Equatable {
    case none
    case interrupted(InterruptionSource)
    case ended
}

/// Observes `AVCaptureSession` and `AVAudioSession` interruption notifications and
/// reports them — it does not touch the capture session or the recording pipeline
/// itself. Callers (see `RecordingViewModel`) decide what to do via the two closures
/// passed to `startObserving`.
@MainActor
final class RecordingInterruptionMonitor: ObservableObject {
    @Published private(set) var status: InterruptionStatus = .none

    private var observers: [NSObjectProtocol] = []
    private var onInterruptionBegan: ((InterruptionSource) async -> Void)?
    private var onInterruptionEnded: (() async -> Void)?

    func startObserving(
        session: AVCaptureSession,
        onInterruptionBegan: @escaping (InterruptionSource) async -> Void,
        onInterruptionEnded: @escaping () async -> Void
    ) {
        stopObserving()
        self.onInterruptionBegan = onInterruptionBegan
        self.onInterruptionEnded = onInterruptionEnded

        let center = NotificationCenter.default

        // `queue: .main` guarantees these fire on the main thread, but the closure
        // type itself isn't MainActor-isolated, so each handler is dispatched through
        // a `Task` to legally call back into this MainActor class.
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main
        ) { [weak self] notification in
            Task { await self?.handleSessionInterrupted(notification) }
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { await self?.handleInterruptionEnded() }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { await self?.handleAudioSessionInterruption(notification) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { await self?.handleRouteChange(notification) }
        })

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.reportInterruption(.appBackground) }
        })
    }

    func stopObserving() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        onInterruptionBegan = nil
        onInterruptionEnded = nil
    }

    // MARK: - Notification handlers

    private func handleSessionInterrupted(_ notification: Notification) {
        reportInterruption(Self.interruptionSource(from: notification))
    }

    private func handleInterruptionEnded() {
        status = .ended
        let callback = onInterruptionEnded
        Task { await callback?() }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            // Public APIs don't distinguish a phone call from Siri here — both surface
            // as a generic "another client took the audio session" interruption.
            reportInterruption(.phoneCall)
        case .ended:
            handleInterruptionEnded()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
            reportInterruption(.audioRouteChange)
        }
    }

    private func reportInterruption(_ source: InterruptionSource) {
        status = .interrupted(source)
        let callback = onInterruptionBegan
        Task { await callback?(source) }
    }

    /// Maps `AVCaptureSession.InterruptionReason` onto our product-level taxonomy.
    /// `AVFoundation` doesn't expose enough detail to tell Lock Screen apart from a
    /// plain background transition, so both map to `.appBackground` here.
    private static func interruptionSource(from notification: Notification) -> InterruptionSource {
        guard let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else {
            return .unknown
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            return .appBackground
        case .audioDeviceInUseByAnotherClient:
            return .phoneCall
        case .videoDeviceInUseByAnotherClient, .videoDeviceNotAvailableWithMultipleForegroundApps:
            return .cameraInUse
        case .videoDeviceNotAvailableDueToSystemPressure, .sensitiveContentMitigationActivated:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}
