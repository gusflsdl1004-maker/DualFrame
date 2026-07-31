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
            // The real crop, unchanged — this is still `CropCalculator` mapped through
            // the preview's own layout, and nothing below alters it.
            let crop = shortFormRectOnScreen(in: screen)
            // Task 086: what to *draw*. The crop can extend past the visible window, and
            // when it does the brackets and edges used to be off-screen — technically
            // right, useless to look at. The drawn box is the crop intersected with the
            // screen, inset by a hair so a 1pt stroke sitting exactly on the edge is not
            // half-clipped. Display only: the crop itself is untouched.
            let frame = drawnFrame(crop: crop, screen: screen)
            let edges = ClippedEdges(crop: crop, screen: screen)

            ZStack {
                // ① The 9:16 frame — **solid, and only where the boundary is real.**
                //
                // Task 087: the dashed sides are gone. You were right that they were hard
                // to read, and there is a better reason to drop them: a clipped side is by
                // definition sitting on the screen edge, hard against the bezel, where no
                // line says much whatever its style. Not drawing it is clearer than
                // drawing it faintly, and it removes the risk of a line at the edge being
                // read as "the short form stops here" when it does not.
                //
                // So every line on screen is a real crop boundary. The brackets below mark
                // the visible framing box, and the absence of a side is what tells the
                // user the short form continues past that edge.
                Path { path in
                    if !edges.leftClipped { path.addLines([CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY)]) }
                    if !edges.rightClipped { path.addLines([CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY)]) }
                    if !edges.topClipped { path.addLines([CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY)]) }
                    if !edges.bottomClipped { path.addLines([CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)]) }
                }
                .stroke(Color.white.opacity(0.7), lineWidth: 1)

                // ② Centre vertical line, ③ centre horizontal line.
                //
                // Always on screen, and not by clamping: the crop is centred in the video
                // and `.resizeAspectFill` centres the video in the screen, so the crop's
                // centre and the screen's centre are the same point. The cross is drawn at
                // the real crop centre and lands in the middle of the screen on its own.
                Path { path in
                    path.move(to: CGPoint(x: crop.midX, y: frame.minY))
                    path.addLine(to: CGPoint(x: crop.midX, y: frame.maxY))
                    path.move(to: CGPoint(x: frame.minX, y: crop.midY))
                    path.addLine(to: CGPoint(x: frame.maxX, y: crop.midY))
                }
                .stroke(Color.white.opacity(0.5), lineWidth: 1)

                // ④ Corner brackets, on the drawn frame so they are always visible. They
                // read as corners through their shape, so they need no extra weight.
                Path { path in
                    let length = min(24, min(frame.width, frame.height) / 5)
                    for (x, dx) in [(frame.minX, CGFloat(1)), (frame.maxX, CGFloat(-1))] {
                        for (y, dy) in [(frame.minY, CGFloat(1)), (frame.maxY, CGFloat(-1))] {
                            path.move(to: CGPoint(x: x + dx * length, y: y))
                            path.addLine(to: CGPoint(x: x, y: y))
                            path.addLine(to: CGPoint(x: x, y: y + dy * length))
                        }
                    }
                }
                .stroke(Color.white.opacity(0.7), lineWidth: 1)
            }
            .clipped()
        }
        // Guide only — never intercepts touches meant for the preview or the controls
        // layered above it.
        .allowsHitTesting(false)
    }

    /// Task 086: which sides of the drawn box are the real crop boundary and which only
    /// exist because the visible window ran out. Purely a drawing question — it reads the
    /// crop, never changes it.
    private struct ClippedEdges {
        let leftClipped: Bool
        let rightClipped: Bool
        let topClipped: Bool
        let bottomClipped: Bool

        init(crop: CGRect, screen: CGSize) {
            leftClipped = crop.minX < 0
            rightClipped = crop.maxX > screen.width
            topClipped = crop.minY < 0
            bottomClipped = crop.maxY > screen.height
        }
    }

    /// The rectangle actually drawn: the crop intersected with the visible window, inset
    /// by a hair so a 1pt stroke centred on the edge is not half-clipped.
    ///
    /// This is the whole of Task 086. The crop rect is unchanged and still comes from
    /// `CropCalculator`; only what gets painted is brought inside the screen, so the
    /// brackets and side lines are always there to look at. The dashed styling above is
    /// what keeps that honest — a side moved in to the screen edge never claims to be the
    /// place the short form ends.
    private func drawnFrame(crop: CGRect, screen: CGSize) -> CGRect {
        let inset: CGFloat = 1
        let bounds = CGRect(origin: .zero, size: screen).insetBy(dx: inset, dy: inset)
        let intersection = crop.intersection(bounds)
        // `.null` when the crop is entirely off-screen — not reachable with a centred
        // crop and a centred preview, but a zero-size frame draws nothing rather than
        // drawing something wrong.
        return intersection.isNull ? .zero : intersection
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
