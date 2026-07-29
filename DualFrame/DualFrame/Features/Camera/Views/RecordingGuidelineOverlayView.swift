//
//  RecordingGuidelineOverlayView.swift
//  DualFrame
//

import SwiftUI

/// Task 040: a purely visual framing guide over the live camera preview, showing
/// where the Long-form (16:9) and Short-form (9:16) outputs would land relative to
/// what's currently on screen — camera output and recording logic are completely
/// untouched, this only draws on top of the already-existing preview.
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
                // Requirement 3: Long guide — thin, unobtrusive white line.
                Rectangle()
                    .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
                    .frame(width: longRect.width, height: longRect.height)
                    .position(x: longRect.midX, y: longRect.midY)

                // Requirement 3/4: Short guide — the actual safe area for short-form,
                // in a more emphasized color so it reads clearly as the stricter
                // boundary of the two.
                Rectangle()
                    .stroke(Color.yellow.opacity(0.85), lineWidth: 2)
                    .frame(width: shortRect.width, height: shortRect.height)
                    .position(x: shortRect.midX, y: shortRect.midY)
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
