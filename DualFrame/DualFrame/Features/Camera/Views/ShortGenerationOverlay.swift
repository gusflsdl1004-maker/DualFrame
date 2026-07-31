//
//  ShortGenerationOverlay.swift
//  DualFrame
//

import SwiftUI

/// A non-blocking banner reporting post-processing short-form generation.
///
/// Task 070 requirement 1/3: this used to be a full-screen dimmed card that the user had
/// to sit through — about 20 seconds of waiting. It is now a banner pinned to the top
/// that never takes over the screen, because generation no longer holds up the recording
/// flow and the user is free to keep shooting, open the library, or leave the app
/// entirely while it finishes.
///
/// Nothing here is load-bearing: completion is also reported by a local notification, so
/// a user who navigated away still finds out. The banner is the in-app echo of that.
///
/// The copy is deliberate about one thing throughout — **the long-form recording is
/// already saved** before this ever appears. Cancelling or failing costs the short-form
/// output and nothing else.
struct ShortGenerationOverlay: View {
    let state: ShortGenerationState
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            switch state {
            case .idle:
                EmptyView()
            case .generating(let progress, _, _):
                banner {
                    HStack(spacing: 10) {
                        ProgressView(value: progress)
                            .frame(width: 70)
                        VStack(alignment: .leading, spacing: 1) {
                            // P0-9: the stage, not just a number — "무엇을 하는 중인지"
                            // is what the percentage alone never says.
                            Text("\(state.stageTitle ?? "") \(Int(progress * 100))%")
                                .font(.caption.monospacedDigit())
                            if let remaining = state.remainingText {
                                Text(remaining)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        Button("취소", action: onCancel)
                            .font(.caption)
                    }
                }
            case .finished:
                banner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("쇼츠 생성 완료").font(.caption.bold())
                        Spacer(minLength: 4)
                        Button("확인", action: onDismiss).font(.caption)
                    }
                }
            case .cancelled:
                banner {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("쇼츠 생성 취소됨").font(.caption.bold())
                            Text("원본 영상은 그대로 있습니다.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("다시", action: onRetry).font(.caption)
                        Button("닫기", action: onDismiss).font(.caption)
                    }
                }
            case .failed(let reason):
                banner {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("쇼츠 생성 실패").font(.caption.bold())
                            Text(reason)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Button("다시", action: onRetry).font(.caption)
                        Button("닫기", action: onDismiss).font(.caption)
                    }
                }
            }
            Spacer()
        }
        // The container must not swallow touches meant for the camera behind it — only
        // the banner itself is interactive. Without this the "non-blocking" claim above
        // would be false regardless of how small the banner looks.
        .allowsHitTesting(state != .idle)
    }

    private func banner<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
