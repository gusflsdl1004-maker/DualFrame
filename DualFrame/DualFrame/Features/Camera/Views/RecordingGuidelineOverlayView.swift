//
//  RecordingGuidelineOverlayView.swift
//  DualFrame
//

import SwiftUI

/// Task 040, reworked in Task 085: a purely visual 9:16 framing guide over the live
/// camera preview. It draws and nothing else — no `AVCaptureVideoPreviewLayer`, no
/// `AVCaptureConnection`, no session, no capture buffer. `CameraService`,
/// `RecordingService` and the crop path are not involved in any way.
///
/// **What makes it honest, and what Task 083 got wrong.**
///
/// The guide has to answer "여기까지가 Short로 저장되는 영역", so the rectangle on screen
/// must be the same region the post-processing crop keeps. Until now this computed a 9:16
/// centre crop of the *screen bounds*, which is a different rectangle entirely, because
/// the preview layer is `.resizeAspectFill`: the video's aspect and the screen's aspect
/// are not the same, so the screen shows a cropped window onto the frame rather than the
/// whole of it.
///
/// Concretely, shooting landscape on a 19.5:9 iPhone in portrait: the screen shows about
/// 26% of the frame's width, while the short-form crop keeps about 32% of it. The old
/// guide drew a full-width box with dim bands top and bottom — describing a horizontal
/// band that the short form never was.
///
/// So the mapping is done properly here:
///
///   1. `CropCalculator` — the same type `ShortGenerationService` uses — computes the crop
///      in **video space**, from the video's own display aspect.
///   2. That rect is mapped through the preview layer's own `.resizeAspectFill` transform
///      into **screen space**.
///
/// The result is the real crop boundary. It can legitimately fall outside the screen: when
/// the short-form region is wider than the visible window, its edges are off-screen, and
/// drawing them clipped is the truthful depiction — the alternative is a rectangle that
/// looks tidy and lies.
///
/// Orientation: read from the container, not from `OrientationManager` (CLAUDE.md rules
/// 52-56 — the recording pipeline's orientation is a separate concern and must never be
/// coupled to how the UI is laid out). `AVCaptureVideoPreviewLayer` rotates its content to
/// the interface orientation on its own, so a landscape container displays the sensor's
/// 16:9 and a portrait one displays its 9:16 rotation.
///
/// Performance: plain SwiftUI shapes in a `GeometryReader`. It re-evaluates only when
/// SwiftUI's diffing sees a size or parameter change, never touches a `CMSampleBuffer`,
/// and has no connection to the capture pipeline.
struct RecordingGuidelineOverlayView: View {
    /// The recording resolution's aspect as **stored**, i.e. landscape (16:9). The display
    /// aspect is derived from the container below.
    var sourceAspect: CGFloat = 16.0 / 9.0

    private let cropCalculator = CropCalculator()

    var body: some View {
        GeometryReader { geometry in
            let screen = geometry.size
            let rect = shortFormRectOnScreen(in: screen)

            ZStack {
                // ① The 9:16 frame itself.
                Path { $0.addRect(rect) }
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)

                // ② Centre vertical line, ③ centre horizontal line. Bounded to the crop
                // rect rather than the screen, so they read as belonging to the frame.
                Path { path in
                    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                }
                .stroke(Color.white.opacity(0.5), lineWidth: 1)

                // ④ Corner brackets. Same weight as everything else — they read as corners
                // through their shape, so they do not need extra contrast to do it.
                Path { path in
                    let length = min(24, min(rect.width, rect.height) / 5)
                    for (x, dx) in [(rect.minX, CGFloat(1)), (rect.maxX, CGFloat(-1))] {
                        for (y, dy) in [(rect.minY, CGFloat(1)), (rect.maxY, CGFloat(-1))] {
                            path.move(to: CGPoint(x: x + dx * length, y: y))
                            path.addLine(to: CGPoint(x: x, y: y))
                            path.addLine(to: CGPoint(x: x, y: y + dy * length))
                        }
                    }
                }
                .stroke(Color.white.opacity(0.7), lineWidth: 1)
            }
            // Anything outside the preview stays outside it — the crop rect can extend
            // past the screen, and the lines should stop at the edge rather than draw
            // over the controls.
            .clipped()
        }
        // Guide only — never intercepts touches meant for the preview or the controls
        // layered above it.
        .allowsHitTesting(false)
    }

    /// The short-form crop, in the container's coordinate space.
    ///
    /// Two steps, in this order: crop in video space (`CropCalculator`, the real rule),
    /// then map through `.resizeAspectFill` into screen space (the preview's own layout).
    /// Doing it in one step against the screen bounds is what made the old guide wrong.
    private func shortFormRectOnScreen(in screen: CGSize) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return .zero }

        // The preview layer rotates its content to the interface orientation, so a
        // portrait container displays the stored landscape frame rotated.
        let isLandscape = screen.width > screen.height
        let displayAspect = isLandscape ? sourceAspect : 1 / sourceAspect

        // Any size with the right aspect works — everything below is proportional.
        let video = CGSize(width: displayAspect * 1000, height: 1000)
        let cropInVideo = cropCalculator.cropRect(
            sourceSize: video,
            configuration: CropConfiguration(targetSize: Self.shortFormTargetSize, strategy: .center)
        )

        // `.resizeAspectFill`: scale so the video covers the container, centred, with the
        // overflow cropped equally on both sides. This is the layer's own rule, restated.
        let scale = max(screen.width / video.width, screen.height / video.height)
        let displayed = CGSize(width: video.width * scale, height: video.height * scale)
        let origin = CGPoint(
            x: (screen.width - displayed.width) / 2,
            y: (screen.height - displayed.height) / 2
        )

        return CGRect(
            x: origin.x + cropInVideo.minX * scale,
            y: origin.y + cropInVideo.minY * scale,
            width: cropInVideo.width * scale,
            height: cropInVideo.height * scale
        )
    }

    /// The short-form output's real dimensions, so the guide and the crop can never
    /// disagree about what 9:16 means.
    private static var shortFormTargetSize: CGSize {
        CGSize(
            width: OutputProfile.shortForm.resolution.width,
            height: OutputProfile.shortForm.resolution.height
        )
    }
}

#Preview("Portrait") {
    ZStack {
        LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom)
        RecordingGuidelineOverlayView()
    }
    .ignoresSafeArea()
}

#Preview("Landscape") {
    ZStack {
        LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom)
        RecordingGuidelineOverlayView()
    }
    .frame(width: 700, height: 340)
}
