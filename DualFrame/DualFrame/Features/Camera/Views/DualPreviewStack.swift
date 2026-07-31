//
//  DualPreviewStack.swift
//  DualFrame
//

import AVFoundation
import SwiftUI

/// Task 075 (UI 개편) P0-1: both results, as real previews rather than a guide.
///
/// The vertical result sits above the horizontal one, both fed by the **same**
/// `AVCaptureSession` through separate `AVCaptureVideoPreviewLayer`s. Preview layers are
/// display-side observers — no `AVCaptureVideoDataOutput`, no writer — so this adds no
/// consumer to the capture pipeline. The distinction matters: Task 069 moved short-form
/// generation out of the recording path because a second *writer* cost 8fps at 4K60, and
/// two previews are not that.
///
/// Each pane is `.resizeAspectFill` inside its true output aspect, which is what makes
/// them honest rather than illustrative. Filling 9:16 from a 16:9 source crops left and
/// right evenly — the same centre crop `CropCalculator` computes and
/// `ShortGenerationService` performs. So the top pane is the short-form file, not a
/// drawing of where it would be.
///
/// **Long is the main pane.** It is what is actually being recorded, so it gets the
/// space; the short pane above answers "쇼츠에서는 이렇게 저장됩니다" and needs only
/// enough size to judge the crop. (Task 077 briefly had this the other way round — the
/// vertical pane as the subject — which made the recording itself the smaller image.)
struct DualPreviewStack: View {
    let session: AVCaptureSession
    let cameraService: CameraService
    /// When false only the long-form pane is shown — previewing a short-form file that
    /// will never be generated would be a lie.
    var showsShortPane: Bool
    /// Task 077 condition ③: the short pane's layer is created and laid out but left
    /// unconnected, so only the connection's cost is removed.
    var connectsShortPane: Bool = true

    var body: some View {
        GeometryReader { geometry in
            if showsShortPane {
                // Task 077 #1: the two panes are pushed up as a group and the
                // horizontal one shrinks, so the hierarchy reads as "vertical is the
                // shot, horizontal is reference" rather than two equal windows.
                //
                // `bottomReserve` is the part that actually fixes the complaint: the
                // stack is laid out inside the height that remains *after* the shutter
                // area, so the panes can no longer sit under the record button no
                // matter how tall the device is. Reserving space beats nudging offsets,
                // which drift per screen size.
                // P0-2: more room at the bottom pushes the whole stack down and away
                // from the shutter, which was the "답답하다" complaint.
                let bottomReserve: CGFloat = 228
                let usableHeight = max(0, geometry.size.height - bottomReserve)

                VStack(spacing: 18) {
                    pane(
                        label: "SHORT",
                        detail: "9:16 · 쇼츠 저장 결과",
                        aspect: 9.0 / 16.0,
                        available: CGSize(width: geometry.size.width, height: usableHeight),
                        heightFraction: 0.44,
                        emphasized: false,
                        connected: connectsShortPane
                    )
                    pane(
                        label: "LONG",
                        detail: "16:9 · 녹화 중인 화면",
                        aspect: 16.0 / 9.0,
                        available: CGSize(width: geometry.size.width, height: usableHeight),
                        heightFraction: 0.52,
                        emphasized: true,
                        // Task 079 P0: the long pane takes the session's **automatic**
                        // preview connection. Task 076 gave both panes explicit ones,
                        // which meant that when the explicit path failed there was no
                        // live image at all — the whole camera screen went black. The
                        // session grants exactly one automatic connection, and the pane
                        // showing what is actually being recorded is the one that should
                        // have it: it now comes up without depending on anything.
                        usesAutomaticConnection: true
                    )
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: usableHeight, alignment: .top)
                .padding(.top, 96)
            } else {
                CameraPreviewRepresentable(session: session)
            }
        }
    }

    /// One preview pane, sized to fit its aspect inside the slice it is given. Height is
    /// the constraint on a phone, so the width follows from the aspect rather than the
    /// other way round — that keeps both panes at their true shape instead of stretching
    /// either one to fill.
    private func pane(
        label: String,
        detail: String,
        aspect: CGFloat,
        available: CGSize,
        heightFraction: CGFloat,
        emphasized: Bool,
        connected: Bool = true,
        usesAutomaticConnection: Bool = false
    ) -> some View {
        let maxHeight = available.height * heightFraction
        let width = min(available.width, maxHeight * aspect)
        let height = width / aspect

        return ZStack(alignment: .topLeading) {
            // Both panes are real `AVCaptureVideoPreviewLayer`s on the same session —
            // neither is a guide, a mask, or a still. Both use `.resizeAspectFill` inside
            // their true output aspect, so the 9:16 pane shows the real centre crop and
            // the 16:9 pane shows the full frame, live and moving together.
            //
            // They differ only in *how* they are connected. `CameraPreviewRepresentable`
            // takes the session's single automatic connection — the path this app has
            // always used, which needs nothing from us. `ShortPreviewRepresentable` needs
            // an explicit one, which only `CameraService` may add.
            Group {
                if usesAutomaticConnection {
                    CameraPreviewRepresentable(session: session)
                } else {
                    ShortPreviewRepresentable(
                        session: session,
                        cameraService: cameraService,
                        connected: connected
                    )
                }
            }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        // The short pane is the one being composed, so it carries the
                        // brighter edge. The long pane is context, not the subject.
                        .stroke(.white.opacity(emphasized ? 0.9 : 0.28), lineWidth: emphasized ? 2 : 1)
                )
                // Only the subject pane lifts off the background. Shadowing both would
                // flatten the distinction the border is making.
                .shadow(color: .black.opacity(emphasized ? 0.35 : 0), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.bold())
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            .padding(8)
            .opacity(emphasized ? 1 : 0.75)
        }
        .frame(width: width, height: height)
        .frame(maxWidth: .infinity)
    }
}
