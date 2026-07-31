//
//  RecordingGuidelineOverlayView.swift
//  DualFrame
//

import SwiftUI

/// Task 040, reworked in Task 072 (P0-2): a purely visual framing guide over the live
/// camera preview — camera output and recording logic are completely untouched, this
/// only draws on top of the already-existing preview.
///
/// It no longer draws guide lines. The area outside the 9:16 crop is dimmed, so the
/// bright region *is* the short-form result and the full screen is the long-form one.
/// The user can predict both outputs before pressing record, which two outlines never
/// actually conveyed.
///
/// Both guides reuse `CropCalculator` — the same type `RecordingService`'s actual
/// short-form crop path uses — computing a center-crop rect of the *current preview
/// bounds* against each output's real aspect ratio (`OutputProfile.longForm`/
/// `.shortForm`). Reusing the real crop math (rather than a hand-rolled ratio) is
/// what keeps the Short guide an honest "safe area" — if it drifts from
/// `VideoFrameCropper`'s actual behavior, both would drift together since they share
/// the same source of truth.
///
/// Orientation (requirement 7): deliberately reads no orientation state at all — this
/// app's `Info.plist` only declares Portrait/LandscapeLeft/LandscapeRight as supported
/// interface orientations for iPhone (Portrait Upside Down is not, so the UI itself
/// never visually rotates for it). `GeometryReader`'s reported size already reflects
/// whichever of those layouts is currently active, and `CropCalculator`'s center-crop
/// math is symmetric — it naturally crops left/right when the container is wider than
/// the target aspect and top/bottom when narrower, so the same code path is correct
/// for both portrait and landscape without a manual orientation switch.
///
/// Performance (requirement 6): a plain SwiftUI `View` built from `Rectangle` shapes
/// inside a `GeometryReader` — it only re-evaluates when SwiftUI's own diffing detects
/// a relevant change (the view's size, from rotation, or `isEnabled` toggling). It
/// never touches a `CMSampleBuffer`, is not driven by any per-frame callback, and has
/// no connection to the 30/60fps capture pipeline at all.
struct RecordingGuidelineOverlayView: View {
    private let cropCalculator = CropCalculator()

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let longRect = cropCalculator.cropRect(
                sourceSize: size,
                configuration: CropConfiguration(targetSize: Self.longFormTargetSize, strategy: .center)
            )
            let shortRect = cropCalculator.cropRect(
                sourceSize: size,
                configuration: CropConfiguration(targetSize: Self.shortFormTargetSize, strategy: .center)
            )

            ZStack {
                // Task 082: **a light touch, not a second screen.**
                //
                // Three elements and nothing else — a soft mask, a hairline border, and
                // the two vertical edges of the crop. The previous version dimmed at 0.45
                // with a 2pt border, a LONG badge and a sentence of Korean, which read as
                // a UI panel laid over the shot rather than a guide. It also competed with
                // the live image the user is actually framing.
                //
                // Drawn with `.evenOdd` so the dim is one shape with the crop punched out
                // of it, rather than four rectangles that would seam at the corners.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(shortRect)
                }
                .fill(Color.black.opacity(0.28), style: FillStyle(eoFill: true))

                // The two vertical guides. In portrait these *are* the crop boundary —
                // the 9:16 rect is full height, so the left and right edges are the only
                // part of the border that carries information. Drawn slightly brighter
                // than the frame so the eye lands on them.
                Path { path in
                    path.move(to: CGPoint(x: shortRect.minX, y: shortRect.minY))
                    path.addLine(to: CGPoint(x: shortRect.minX, y: shortRect.maxY))
                    path.move(to: CGPoint(x: shortRect.maxX, y: shortRect.minY))
                    path.addLine(to: CGPoint(x: shortRect.maxX, y: shortRect.maxY))
                }
                .stroke(Color.white.opacity(0.55), lineWidth: 1)

                // A hairline all the way round, so the crop still reads as a rectangle in
                // landscape where the boundary is top/bottom rather than left/right.
                Rectangle()
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
                    .frame(width: shortRect.width, height: shortRect.height)
                    .position(x: shortRect.midX, y: shortRect.midY)

                // One short label instead of a sentence. Only shown when a short-form file
                // is actually going to be produced — see `isEnabled` at the call site.
                Text("9:16")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.3), in: Capsule())
                    .position(x: shortRect.midX, y: shortRect.minY + 16)
            }
        }
        // Requirement 1: guide only — never intercepts touches meant for the preview
        // or the controls layered above it.
        .allowsHitTesting(false)
    }

    private static var longFormTargetSize: CGSize {
        CGSize(width: OutputProfile.longForm.resolution.width, height: OutputProfile.longForm.resolution.height)
    }

    private static var shortFormTargetSize: CGSize {
        CGSize(width: OutputProfile.shortForm.resolution.width, height: OutputProfile.shortForm.resolution.height)
    }
}

#Preview {
    ZStack {
        Color.black
        RecordingGuidelineOverlayView()
    }
    .ignoresSafeArea()
}
