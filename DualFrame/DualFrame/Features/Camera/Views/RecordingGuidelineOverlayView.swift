//
//  RecordingGuidelineOverlayView.swift
//  DualFrame
//

import SwiftUI

/// Task 088 P1: two vertical lines dividing the frame into exact thirds.
///
///     |     |     |
///
/// A composition guide and nothing more. It is deliberately **not** tied to the
/// short-form crop: the 9:16 frame, corner brackets, centre cross and the
/// `CropCalculator` mapping that Tasks 083-087 built are all gone. Those answered "where
/// does the short form end", which turned out to be a question with an awkward answer —
/// the crop routinely extends past the visible window, so the guide was either off-screen
/// or clipped to an edge that was not really the boundary.
///
/// This answers a different and more useful question while shooting: where are the left,
/// centre and right thirds. That is a framing decision the user actually makes, it needs
/// no knowledge of the capture format, and it is correct at any screen size or
/// orientation because thirds of the screen are thirds of the screen.
///
/// Draws only. No `AVCaptureVideoPreviewLayer`, no `AVCaptureConnection`, no session, no
/// capture buffer — `CameraService`, `RecordingService` and `CropCalculator` are not
/// involved and were not touched. `allowsHitTesting(false)`, so every touch goes through
/// to the preview and the controls.
struct RecordingGuidelineOverlayView: View {
    var body: some View {
        GeometryReader { geometry in
            let third = geometry.size.width / 3

            Path { path in
                for index in 1...2 {
                    let x = third * CGFloat(index)
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }
            }
            // 45% white: readable against a bright sky and against a dark interior, faint
            // enough that it never competes with the subject. A hairline at full opacity
            // reads as part of the scene rather than as an overlay.
            .stroke(Color.white.opacity(0.45), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        RecordingGuidelineOverlayView()
    }
    .ignoresSafeArea()
}
