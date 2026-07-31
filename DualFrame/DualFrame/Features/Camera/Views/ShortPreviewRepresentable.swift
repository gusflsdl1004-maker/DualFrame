//
//  ShortPreviewRepresentable.swift
//  DualFrame
//

import AVFoundation
import SwiftUI

/// Task 079: how a secondary preview attach ended, for logging only. Never thrown and
/// never acted on — a preview that fails to connect must never affect recording.
nonisolated enum SecondaryPreviewAttachResult: String, Sendable {
    case alreadyConnected
    case queuedUntilConfigured
    /// The session was already configured when this layer asked, so there is no safe
    /// moment left to add a connection this launch. Terminal, and deliberately not
    /// retried: retrying meant reconfiguring a running session, which is what froze
    /// recording in Task 079.
    case tooLateThisLaunch
    case noVideoPort
    case rejected
    case connected
}

/// Task 079: carries an `AVCaptureVideoPreviewLayer` to `CameraService`.
///
/// `AVCaptureVideoPreviewLayer` is not `Sendable`, but the actor only uses it to build an
/// `AVCaptureConnection` and hand that to the session — it never touches layer geometry or
/// contents, which stay on the main thread. This is the same trade `CameraService` already
/// makes for `session` itself (`nonisolated(unsafe)`), and the same one Apple's AVCam
/// sample makes. The box is also the identity the actor tracks, so a view can unregister
/// exactly what it registered.
final class PreviewLayerBox: @unchecked Sendable {
    /// `nonisolated(unsafe)` for the same reason `CameraService.session` is: the actor
    /// reads it only to build a connection, which AVFoundation explicitly supports off
    /// the main thread. Without it every access from the actor is a Swift 6 error.
    nonisolated(unsafe) let layer: AVCaptureVideoPreviewLayer

    init(layer: AVCaptureVideoPreviewLayer) {
        self.layer = layer
    }
}

/// Task 076 P0-1: a live picture-in-picture of what the short-form output will be.
///
/// A second `AVCaptureVideoPreviewLayer` on the **same** `AVCaptureSession`. Preview
/// layers are display-side observers — they take no `AVCaptureVideoDataOutput` buffers
/// and add no writer — so this cannot affect capture throughput. That matters here more
/// than usual: Task 069 moved short-form generation out of the recording path precisely
/// because a second *writer* cost 8fps, and this must not quietly reintroduce a second
/// consumer.
///
/// `.resizeAspectFill` inside a 9:16 frame is what makes the PIP honest rather than
/// decorative: filling a 9:16 box from a 16:9 source crops the left and right edges
/// evenly, which is the same centre crop `CropCalculator` computes and
/// `ShortGenerationService` actually performs. The PIP is therefore the real result, not
/// an approximation of it — if the crop rule ever changes, this drifts with it rather
/// than silently disagreeing.
final class ShortPreviewLayerView: UIView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private lazy var box = PreviewLayerBox(layer: previewLayer)
    private var registeredService: CameraService?

    /// Task 079: hands the connection back rather than leaving it on the session. Without
    /// this, every recreation of the SwiftUI view would add another live preview
    /// connection — and unlike the layer, a connection *is* a capture-side consumer.
    deinit {
        guard let registeredService else { return }
        let box = box
        Task.detached { await registeredService.unregisterSecondaryPreview(box) }
    }
    // `unregisterSecondaryPreview` no longer touches a running session (Task 081), so this
    // cannot reconfigure the camera out from under a recording on rotation.

    #if DEBUG
    /// Kept for the log only. There is no retry any more — `registeredService` being set
    /// is what makes repeat calls no-ops.
    private var attachAttempts = 0
    /// Task 080 item 6: paints the layer red instead of black. If the pane shows red the
    /// layer is on screen, correctly sized and unobscured, and the problem is upstream —
    /// no video is arriving. If it stays black the layer itself is not being drawn, and
    /// the connection is beside the point. One observation splits the search in half.
    private var showsDiagnosticProbe = false
    /// What `attach` was last handed, so the log can assert layer and caller agree on the
    /// session object rather than just reporting that some session is bound.
    private weak var expectedSession: AVCaptureSession?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }

    /// Task 076 P0-1: **this is why the second pane was black.**
    ///
    /// Assigning `previewLayer.session` asks AVFoundation to build the connection from
    /// the session's video port to the layer automatically — and a session only supports
    /// **one** such automatic preview connection. The first preview layer takes it; every
    /// later one silently gets nothing and renders black. Nothing errors, which is why it
    /// looked like a layout bug. The supported way to have more than one is to opt out of
    /// the automatic connection and add one explicitly.
    ///
    /// Task 079 P0: **the session transaction moved to `CameraService`.**
    ///
    /// Task 078 opened `beginConfiguration()`/`addConnection`/`commitConfiguration()`
    /// here, on the main thread, from a `didStartRunningNotification` observer. That is
    /// the regression: `CameraService` opens its own transactions from its actor
    /// executor — `configure()` at startup and `refreshRecordingFormat()` from
    /// `startRecording()` — and two unserialised writers of the session's configuration
    /// state can leave it mid-configuration. No frames (black preview) and a commit that
    /// never returns (dead record button) are the two symptoms of exactly that.
    ///
    /// What is left here is layer-side only: `setSessionWithNoConnection` binds the layer
    /// and opens no transaction. The connection itself is requested from the actor, which
    /// queues it until `configure()` can add it inside its existing transaction — so the
    /// session is never reconfigured while running, either.
    ///
    /// `connected: false` is Task 077's condition ③ — the layer is created, sized and laid
    /// out exactly as in ②, but gets no capture connection, so it renders black on
    /// purpose. That is what isolates the connection's cost from the layer's.
    func attach(session: AVCaptureSession, cameraService: CameraService, connected: Bool) {
        #if DEBUG
        expectedSession = session
        #endif
        if previewLayer.session !== session {
            previewLayer.setSessionWithNoConnection(session)
        }
        guard connected else {
            #if DEBUG
            logDiagnostics(stage: "disconnected-by-mode", result: nil)
            #endif
            return
        }
        guard previewLayer.connection == nil, registeredService == nil else { return }

        registeredService = cameraService
        #if DEBUG
        attachAttempts += 1
        #endif
        let box = box
        // Task 081 P0: **registers exactly once, and never retries.**
        //
        // Task 079/080 retried every two seconds, and each retry asked `CameraService` to
        // reconfigure a *running* session — a heavyweight blocking operation, happening in
        // the background, on the same actor the record button needs. The request is now a
        // single non-blocking enqueue that `configure()` drains inside the transaction it
        // already opens. `weak self` throughout, so the delayed read-back below cannot hold
        // a torn-down pane alive past its `deinit`.
        Task { @MainActor [weak self] in
            let result = await cameraService.registerSecondaryPreview(box)
            #if DEBUG
            self?.logDiagnostics(stage: "attach", result: result)
            // Read back once, purely to report — no retry, nothing touched. By now
            // `configure()` has bound the device, so the census reflects what the port
            // pick actually saw.
            try? await Task.sleep(for: .seconds(2))
            self?.logDiagnostics(stage: "settled", result: nil)
            self?.logPortCensus(session: session)
            #endif
        }
    }

    #if DEBUG

    /// Task 080 items 1-5, on **one line** — Xcode's console filter matches per line, so a
    /// multi-line dump loses everything below the tagged row (the Task 077 mistake).
    ///
    /// Split into three groups, because they answer three different questions:
    /// - `conn*` — is a connection there and is it live? (items 1, 4)
    /// - `sameSession` — is it the session the long pane is showing? (item 2)
    /// - `view*`/`layer*`/`window`/`hidden`/`alpha` — is the layer on screen at a real
    ///   size and unobscured? (items 3, 5)
    /// Task 080: **the one real difference from Apple's two-preview sample.**
    ///
    /// `CameraService` picks the port with
    /// `ports(for: .video, sourceDeviceType: nil, sourceDevicePosition: .unspecified).first`.
    /// On a *virtual* multi-lens device (`.builtInDualWideCamera`, `.builtInTripleCamera`
    /// — which `bestAvailableDevice` binds whenever the requested quality/FPS allows it)
    /// that input exposes **more than one** video port: the virtual device's own, plus one
    /// per constituent lens. `nil` matches all of them and `.first` takes whichever comes
    /// back first, which is exactly the kind of inferable-order identity CLAUDE.md rule 62
    /// forbids. AVMultiCamPiP always passes an explicit `sourceDeviceType`.
    ///
    /// If the wrong port is picked, `canAddConnection` can refuse it — or accept it and
    /// show nothing. So the census prints every candidate and marks the one `.first`
    /// currently returns, which turns "we picked a port" into "we picked *this* port out
    /// of these". Read-only: it never changes the pick.
    @MainActor
    private func logPortCensus(session: AVCaptureSession) {
        for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
        where input.device.hasMediaType(.video) {
            let device = input.device
            let ports = input.ports(for: .video, sourceDeviceType: nil, sourceDevicePosition: .unspecified)
            let described = ports.enumerated().map { index, port in
                let type = port.sourceDeviceType?.rawValue
                    .replacingOccurrences(of: "AVCaptureDeviceType", with: "") ?? "nil"
                return "\(index == 0 ? "*" : "")\(type)@\(port.sourceDevicePosition.rawValue)"
            }.joined(separator: ",")

            let line = "[Task080-Ports]"
                + " device=\(device.deviceType.rawValue.replacingOccurrences(of: "AVCaptureDeviceType", with: ""))"
                + " isVirtual=\(device.constituentDevices.count > 1)"
                + " constituents=\(device.constituentDevices.count)"
                + " videoPortCount=\(ports.count)"
                + " ports=[\(described)]"
                + " (* = the one CameraService picks)"
            Task.detached(priority: .utility) { print(line) }
        }
    }

    @MainActor
    private func logDiagnostics(stage: String, result: SecondaryPreviewAttachResult?) {
        let connection = previewLayer.connection
        let boundSession = previewLayer.session
        let rotation = connection.map { String(format: "%.0f", $0.videoRotationAngle) } ?? "n/a"
        let bg = previewLayer.backgroundColor.map { String(describing: $0) } ?? "nil"

        let line = "[Task080-Preview]"
            + " stage=\(stage)"
            + " attempt=\(attachAttempts)"
            + " result=\(result?.rawValue ?? "-")"
            + " probe=\(showsDiagnosticProbe)"
            // item 1 + 4
            + " hasConnection=\(connection != nil)"
            + " connActive=\(connection.map { String(describing: $0.isActive) } ?? "n/a")"
            + " connEnabled=\(connection.map { String(describing: $0.isEnabled) } ?? "n/a")"
            + " connRotation=\(rotation)"
            // item 2 — identity, not equality: the long pane and this one must be showing
            // the same object, and `CameraService` owns exactly one.
            + " sameSession=\(boundSession != nil && boundSession === expectedSession)"
            + " sessionRunning=\(boundSession?.isRunning.description ?? "nil")"
            // item 3 + 5
            + " viewBounds=\(Int(bounds.width))x\(Int(bounds.height))"
            + " layerFrame=\(Int(previewLayer.frame.width))x\(Int(previewLayer.frame.height))"
            + " window=\(window != nil)"
            + " hidden=\(isHidden)/\(previewLayer.isHidden)"
            + " alpha=\(alpha)/\(previewLayer.opacity)"
            + " gravity=\(previewLayer.videoGravity.rawValue)"
            + " layerBG=\(bg)"
        Task.detached(priority: .utility) { print(line) }
    }
    #endif

    private func setUp() {
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
        layer.masksToBounds = true
        layer.addSublayer(previewLayer)

        #if DEBUG
        // Task 080 item 6. Read here rather than threaded through three view layers —
        // it is a UserDefaults read once per view creation, in Debug only.
        showsDiagnosticProbe = SecondPreviewSettingsService().load().showsDiagnosticProbe
        if showsDiagnosticProbe {
            // The *layer's* background, not the view's: a red view behind a correctly
            // drawn but empty preview layer would look identical to a red preview layer,
            // and only the latter proves the layer itself is on screen.
            previewLayer.backgroundColor = UIColor.systemRed.cgColor
        }
        #endif
    }
}

struct ShortPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraService: CameraService
    var connected: Bool = true

    func makeUIView(context: Context) -> ShortPreviewLayerView {
        let view = ShortPreviewLayerView()
        view.attach(session: session, cameraService: cameraService, connected: connected)
        return view
    }

    /// An extra chance, not the mechanism — `attach` is a no-op once a connection exists
    /// or a registration is outstanding. The registration queued inside `CameraService` is
    /// what actually guarantees the connection, so this no longer has to fire for the pane
    /// to come alive (which is what Task 078 was working around).
    func updateUIView(_ uiView: ShortPreviewLayerView, context: Context) {
        uiView.attach(session: session, cameraService: cameraService, connected: connected)
    }
}

/// The PIP as it appears on the camera screen: the 9:16 preview, a border, and a label.
///
/// P1-1: the label is why this is legible at all. With two live images on screen the
/// user has no way to tell which is which, so the PIP says SHORT and the full-screen
/// preview behind it says LONG.
struct ShortPreviewPIP: View {
    let session: AVCaptureSession
    let cameraService: CameraService
    /// 9:16 at this width. Small enough to leave the long-form framing readable, large
    /// enough to judge what is inside the crop.
    var width: CGFloat = 96

    var body: some View {
        VStack(spacing: 4) {
            Text("SHORT")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())

            ShortPreviewRepresentable(session: session, cameraService: cameraService)
                .frame(width: width, height: width * 16 / 9)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.85), lineWidth: 2)
                )
        }
        // Never intercepts touches — the camera controls sit behind and around it.
        .allowsHitTesting(false)
    }
}
