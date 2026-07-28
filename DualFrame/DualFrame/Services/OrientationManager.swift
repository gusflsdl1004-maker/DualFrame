//
//  OrientationManager.swift
//  DualFrame
//

import AVFoundation
import Combine
import UIKit

/// The four orientations a device can be held in for recording purposes.
/// `UIDeviceOrientation` also has `.faceUp`/`.faceDown`/`.unknown`, which never map to
/// one of these — see `OrientationManager.applyDeviceOrientation(_:)`.
nonisolated enum RecordingOrientation: Equatable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
}

/// The single source of truth for how a captured frame should be oriented before being
/// written to disk (Task 022). Tracks device orientation (`UIDevice`) and interface
/// orientation (the active `UIWindowScene`), and turns them — plus the active camera's
/// position — into a `CGAffineTransform` for `AVAssetWriterInput.transform`.
///
/// This never touches pixel data (requirement 8/9): the transform is pure file-track
/// metadata, read once by `CameraService` right before a recording starts
/// (`CameraService.refreshRecordingOrientation()`) and applied once per writer by
/// `RecordingService` (`RecordingService.updateRecordingTransform`). Neither of those
/// types computes orientation themselves — this is the only place that does (Additional
/// Development Rule, Task 022).
@MainActor
final class OrientationManager: ObservableObject {
    /// The last known "up" direction from `UIDevice.current.orientation`. Stays at its
    /// previous value across `.faceUp`/`.faceDown`/`.unknown` readings — those aren't
    /// usable "up" directions, and holding onto the last real one means setting the
    /// phone flat on a table mid-recording doesn't change anything (requirement 5).
    @Published private(set) var deviceOrientation: RecordingOrientation = .portrait
    /// The active window scene's interface orientation. Not consulted by
    /// `recordingTransform(for:)` today — `deviceOrientation` alone already covers all
    /// four cases, including portrait-upside-down, which this app's iPhone interface
    /// never itself rotates to. Tracked because requirement 1 explicitly asks for
    /// interface-orientation awareness, and kept available as a future fallback for
    /// when device orientation is ambiguous.
    @Published private(set) var interfaceOrientation: UIInterfaceOrientation = .portrait

    private var isObserving = false

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceOrientationChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        refreshInterfaceOrientation()
        applyDeviceOrientation(UIDevice.current.orientation)
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// The transform `RecordingService` should apply to a writer's video input so the
    /// saved file plays back right-side-up, for the current orientation and `position`.
    ///
    /// Convention (standard for `AVAssetWriter`-based capture; **not verified on real
    /// hardware** — see the Task 022 report's Known Issues): the rear camera's sensor
    /// is mounted so `.landscapeLeft` needs no rotation and `.landscapeRight` needs
    /// 180°; the front camera's sensor is mounted rotated 180° relative to the rear
    /// one, so those two invert. Portrait/portrait-upside-down use the same angle for
    /// both cameras.
    func recordingTransform(for position: AVCaptureDevice.Position) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: Self.rotationAngle(for: deviceOrientation, position: position))
    }

    /// Whether the *recorded* file should be horizontally flipped for `position`.
    /// Always `false` — recorded video is never mirrored, even for the front camera
    /// (requirement 3: a saved selfie should look like everyone else's recordings look
    /// of you, not like your own mirror reflection). A live preview mirroring the front
    /// camera for a natural "looking in a mirror" feel while framing a shot is a
    /// separate, UI-layer concern this task doesn't touch (no UI redesign).
    func shouldMirrorRecording(for position: AVCaptureDevice.Position) -> Bool {
        false
    }

    @objc private func handleDeviceOrientationChange() {
        applyDeviceOrientation(UIDevice.current.orientation)
        refreshInterfaceOrientation()
    }

    private func applyDeviceOrientation(_ orientation: UIDeviceOrientation) {
        guard let mapped = Self.mapDeviceOrientation(orientation) else { return }
        deviceOrientation = mapped
    }

    private func refreshInterfaceOrientation() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        interfaceOrientation = scene.effectiveGeometry.interfaceOrientation
    }

    private static func mapDeviceOrientation(_ orientation: UIDeviceOrientation) -> RecordingOrientation? {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }

    private static func rotationAngle(for orientation: RecordingOrientation, position: AVCaptureDevice.Position) -> CGFloat {
        switch orientation {
        case .portrait: .pi / 2
        case .portraitUpsideDown: -.pi / 2
        case .landscapeLeft: position == .front ? .pi : 0
        case .landscapeRight: position == .front ? 0 : .pi
        }
    }
}
