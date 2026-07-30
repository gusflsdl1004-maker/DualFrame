//
//  ShortGenerationOverlay.swift
//  DualFrame
//

import SwiftUI

/// Task 069 Phase 3: what the user sees while the short-form output is being derived
/// from the finished long-form recording.
///
/// The wording is deliberate about the one thing that matters if something goes wrong:
/// **the long-form recording is already saved before this appears.** Cancelling or a
/// failure here costs the short-form output and nothing else, and the copy says so
/// rather than leaving the user to wonder whether their footage survived.
///
/// Shown as an overlay on the camera screen rather than a modal, so the shot the user
/// just took stays visible behind it.
struct ShortGenerationOverlay: View {
    let state: ShortGenerationState
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .generating(let progress):
            card {
                Text("쇼츠 영상을 생성하는 중…")
                    .font(.headline)
                ProgressView(value: progress)
                    .tint(.white)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("원본 영상은 이미 저장되었습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("취소", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
            }
        case .finished:
            card {
                Label("쇼츠 생성 완료", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Button("확인", action: onDismiss)
                    .buttonStyle(.borderedProminent)
            }
        case .cancelled:
            card {
                Label("쇼츠 생성을 취소했습니다", systemImage: "xmark.circle")
                    .font(.headline)
                Text("원본 영상은 그대로 저장되어 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("닫기", action: onDismiss)
                        .buttonStyle(.bordered)
                    Button("다시 생성", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
            }
        case .failed(let reason):
            card {
                Label("쇼츠 생성에 실패했습니다", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("원본 영상은 삭제되지 않았습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("닫기", action: onDismiss)
                        .buttonStyle(.bordered)
                    Button("다시 생성", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            content()
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
        .ignoresSafeArea()
    }
}
