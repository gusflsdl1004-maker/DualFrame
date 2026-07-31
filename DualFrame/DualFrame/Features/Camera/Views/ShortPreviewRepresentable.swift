//
//  ShortPreviewRepresentable.swift
//  DualFrame
//

import AVFoundation
import SwiftUI

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
    #if DEBUG
    /// Task 077: how many times `attach` has been asked to do work. `updateUIView` calls
    /// it on every SwiftUI update, so this counts only the attempts made *before* a
    /// connection existed — the ones that matter for "did it ever connect, and on which
    /// pass". Logging every call would flood the console with no-ops.
    private var attachAttempts = 0
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
    /// looked like a layout bug.
    ///
    /// The supported way to have more than one is to opt out of the automatic connection
    /// and add one explicitly, which is what `AVCaptureMultiCamSession` samples do.
    /// `connected: false` is Task 077's condition ③ — the layer is created, sized and
    /// laid out exactly as in ②, but gets no capture connection, so it renders black on
    /// purpose. That is what isolates the connection's cost from the layer's.
    ///
    /// Task 078 P0-1: **idempotent and safe to call repeatedly, which is the fix for the
    /// black pane.** `makeUIView` runs once, at view-creation time — and at that moment
    /// `CameraService.configure()` has usually not finished, so `session.inputs` is
    /// empty, the port lookup below fails, and the early return leaves the layer
    /// permanently unconnected. Nothing retried it.
    ///
    /// The full-screen preview never had this problem because `previewLayer.session = `
    /// hands the wiring to AVFoundation, which connects whenever an input appears. A
    /// manual connection has no such observer, so the caller drives it from
    /// `updateUIView` as well and the guards below make the repeat calls free.
    ///
    /// Returns whether the layer now has a connection, so the caller knows to stop.
    @discardableResult
    func attach(session: AVCaptureSession, connected: Bool) -> Bool {
        guard previewLayer.connection == nil else { return true }

        #if DEBUG
        attachAttempts += 1
        #endif

        if previewLayer.session !== session {
            previewLayer.setSessionWithNoConnection(session)
        }
        guard connected else {
            #if DEBUG
            log(canAdd: nil, added: false, note: "connected=false (실험 조건 ③ — 의도된 미연결)")
            #endif
            return false
        }

        guard let videoPort = session.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) })?
            .ports(for: .video, sourceDeviceType: nil, sourceDevicePosition: .unspecified)
            .first
        else {
            // The session has no video input yet. Not an error — `updateUIView` calls
            // back and this succeeds on a later pass.
            #if DEBUG
            log(canAdd: nil, added: false, note: "no video input port yet (configure 미완료)")
            #endif
            return false
        }

        let connection = AVCaptureConnection(inputPort: videoPort, videoPreviewLayer: previewLayer)
        let canAdd = session.canAddConnection(connection)
        guard canAdd else {
            #if DEBUG
            log(canAdd: false, added: false, note: "세션이 두 번째 프리뷰 연결을 거부함")
            #endif
            return false
        }

        // A configuration transaction on a running session. It adds a *preview*
        // connection only — no output, no writer — so it cannot change what the capture
        // pipeline delivers to `RecordingService`. Still wrapped, because AVFoundation
        // re-resolves the session around an unwrapped change and Task 044 established
        // that as a way to silently lose the frame duration.
        session.beginConfiguration()
        session.addConnection(connection)
        session.commitConfiguration()

        #if DEBUG
        // `isActive` is read after `commitConfiguration`, which is when the session has
        // actually resolved the connection — reading it before the commit would report
        // the pre-resolution value and be misleading.
        log(canAdd: true, added: true, note: nil, connection: connection)
        #endif
        return true
    }

    #if DEBUG
    private func log(canAdd: Bool?, added: Bool, note: String?, connection: AVCaptureConnection? = nil) {
        let target = connection ?? previewLayer.connection
        var line = """
        [Task077-Preview]
        attachAttempt=\(attachAttempts)
        canAddConnection=\(canAdd.map(String.init(describing:)) ?? "n/a")
        connectionAdded=\(added)
        isActive=\(target.map { String(describing: $0.isActive) } ?? "n/a")
        isEnabled=\(target.map { String(describing: $0.isEnabled) } ?? "n/a")
        """
        if let note { line += "\nnote=\(note)" }
        // Handed off, matching every other diagnostic in this project — a synchronous
        // print here runs during a SwiftUI update and on the same thread that just
        // committed a session configuration.
        Task.detached(priority: .utility) { print(line) }
    }
    #endif

    private func setUp() {
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        layer.masksToBounds = true
    }
}

struct ShortPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession
    var connected: Bool = true

    func makeUIView(context: Context) -> ShortPreviewLayerView {
        let view = ShortPreviewLayerView()
        view.attach(session: session, connected: connected)
        return view
    }

    /// The retry that makes the connection actually happen. SwiftUI calls this whenever
    /// the surrounding view updates — which includes the state changes that follow
    /// `CameraService.configure()` completing — and `attach` is a no-op once connected.
    func updateUIView(_ uiView: ShortPreviewLayerView, context: Context) {
        uiView.attach(session: session, connected: connected)
    }
}

/// The PIP as it appears on the camera screen: the 9:16 preview, a border, and a label.
///
/// P1-1: the label is why this is legible at all. With two live images on screen the
/// user has no way to tell which is which, so the PIP says SHORT and the full-screen
/// preview behind it says LONG.
struct ShortPreviewPIP: View {
    let session: AVCaptureSession
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

            ShortPreviewRepresentable(session: session)
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
