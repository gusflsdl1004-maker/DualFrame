//
//  CameraPreviewRepresentable.swift
//  DualFrame
//

import AVFoundation
import SwiftUI

/// Hosts an `AVCaptureVideoPreviewLayer` sized to fill its bounds.
final class CameraPreviewLayerView: UIView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpPreviewLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpPreviewLayer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }

    func attach(session: AVCaptureSession) {
        previewLayer.session = session
    }

    private func setUpPreviewLayer() {
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
        layer.addSublayer(previewLayer)
    }
}

/// Bridges `CameraPreviewLayerView` into SwiftUI.
struct CameraPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewLayerView {
        let view = CameraPreviewLayerView()
        view.attach(session: session)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewLayerView, context: Context) {}
}
