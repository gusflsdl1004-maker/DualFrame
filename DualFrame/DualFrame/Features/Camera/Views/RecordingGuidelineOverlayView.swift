//
//  RecordingGuidelineOverlayView.swift
//  DualFrame
//

import SwiftUI

/// Task 089: two horizontal lines dividing the frame into exact thirds.
///
///     ─────────────
///     ─────────────
///
/// A composition guide and nothing more. It is deliberately **not** tied to the
/// short-form crop: the 9:16 frame, corner brackets, centre cross and the
/// `CropCalculator` mapping that Tasks 083-087 built are all gone. Those answered "where
/// does the short form end", which turned out to be a question with an awkward answer —
/// the crop routinely extends past the visible window, so the guide was either off-screen
/// or clipped to an edge that was not really the boundary.
///
/// Horizontal rather than vertical (Task 088 had it the other way round) because this app
/// shoots long-form 16:9, which means the phone is held **landscape**. Held that way, the
/// thirds a shooter actually places against are the horizontal ones — horizon, eyeline,
/// headroom. Vertical thirds divide the long edge of a landscape frame, which is not the
/// division being judged.
///
/// Draws only. No `AVCaptureVideoPreviewLayer`, no `AVCaptureConnection`, no session, no
/// capture buffer — `CameraService`, `RecordingService` and `CropCalculator` are not
/// involved and were not touched. `allowsHitTesting(false)`, so every touch goes through
/// to the preview and the controls.
struct RecordingGuidelineOverlayView: View {
    var body: some View {
        GeometryReader { geometry in
            // Computed from the container's own height every time it is laid out, so the
            // lines are exact thirds at any screen size and stay exact through rotation.
            // No stored constants and nothing rounded to a point boundary.
            let third = geometry.size.height / 3

            Path { path in
                for index in 1...2 {
                    let y = third * CGFloat(index)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
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
