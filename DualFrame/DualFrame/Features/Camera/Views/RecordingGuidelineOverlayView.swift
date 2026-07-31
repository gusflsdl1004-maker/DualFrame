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
                // Task 072 P0-2: **a frame, not a pair of lines.**
                //
                // Two thin outlines told the user where the boundaries were but not
                // what the result would look like. Everything outside the 9:16 rect is
                // now dimmed instead, so what stays bright *is* the short-form output —
                // the user reads the two results at once: the whole screen is the
                // long-form file, the bright rectangle is the short-form one.
                //
                // Drawn with `.evenOdd` so the dim is a single shape with the crop
                // punched out of it, rather than four rectangles that would seam at the
                // corners.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(shortRect)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

                // The short-form boundary itself, bright enough to read against any
                // scene now that it separates lit from dimmed.
                Rectangle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: shortRect.width, height: shortRect.height)
                    .position(x: shortRect.midX, y: shortRect.midY)

                // The long-form boundary stays as a hairline. It usually coincides with
                // the screen edge, so it needs no emphasis — but on a container whose
                // aspect differs from 16:9 it is the only thing showing what the
                // long-form file will actually contain.
                Rectangle()
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                    .frame(width: longRect.width, height: longRect.height)
                    .position(x: longRect.midX, y: longRect.midY)

                Text("이 영역이 쇼츠로 저장됩니다")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: Capsule())
                    .position(x: shortRect.midX, y: shortRect.minY + 18)
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
