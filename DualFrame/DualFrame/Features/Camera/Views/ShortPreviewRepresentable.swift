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
    func attach(session: AVCaptureSession) {
        guard previewLayer.connection == nil else { return }
        previewLayer.setSessionWithNoConnection(session)

        guard let videoPort = session.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) })?
            .ports(for: .video, sourceDeviceType: nil, sourceDevicePosition: .unspecified)
            .first
        else { return }

        let connection = AVCaptureConnection(inputPort: videoPort, videoPreviewLayer: previewLayer)
        guard session.canAddConnection(connection) else { return }

        // A configuration transaction on a running session. It adds a *preview*
        // connection only — no output, no writer — so it cannot change what the capture
        // pipeline delivers to `RecordingService`. Still wrapped, because AVFoundation
        // re-resolves the session around an unwrapped change and Task 044 established
        // that as a way to silently lose the frame duration.
        session.beginConfiguration()
        session.addConnection(connection)
        session.commitConfiguration()
    }

    private func setUp() {
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        layer.masksToBounds = true
    }
}

struct ShortPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> ShortPreviewLayerView {
        let view = ShortPreviewLayerView()
        view.attach(session: session)
        return view
    }

    func updateUIView(_ uiView: ShortPreviewLayerView, context: Context) {}
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
