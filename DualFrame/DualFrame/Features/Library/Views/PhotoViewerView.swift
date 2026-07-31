//
//  PhotoViewerView.swift
//  DualFrame
//

import SwiftUI

/// Task 091 P1-4: full-screen still viewer — pinch to zoom, drag to pan, double-tap to
/// toggle.
///
/// Loads from the file on demand rather than holding a decoded image in the library list:
/// a 4K still is ~24MB decoded, and keeping one per row would put the gallery's memory
/// use in the hundreds of megabytes on a full library.
struct PhotoViewerView: View {
    let record: PhotoRecord
    @Environment(\.dismiss) private var dismiss

    /// Committed zoom, and the live gesture applied on top of it. Kept separate so a
    /// pinch is always relative to where the previous one ended rather than snapping.
    @State private var scale: CGFloat = 1
    @GestureState private var pinchScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    private var effectiveScale: CGFloat { scale * pinchScale }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    Color.black.ignoresSafeArea()

                    if let image = UIImage(contentsOfFile: record.localURL.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .scaleEffect(effectiveScale)
                            .offset(
                                x: offset.width + dragOffset.width,
                                y: offset.height + dragOffset.height
                            )
                            .gesture(
                                MagnificationGesture()
                                    .updating($pinchScale) { value, state, _ in state = value }
                                    .onEnded { value in
                                        // Clamped on commit, not during: clamping live
                                        // makes the image fight the fingers.
                                        scale = min(max(scale * value, 1), 6)
                                        if scale == 1 { offset = .zero }
                                    }
                            )
                            .simultaneousGesture(
                                DragGesture()
                                    .updating($dragOffset) { value, state, _ in
                                        // Panning only means anything while zoomed in.
                                        guard effectiveScale > 1 else { return }
                                        state = value.translation
                                    }
                                    .onEnded { value in
                                        guard effectiveScale > 1 else { return }
                                        offset.width += value.translation.width
                                        offset.height += value.translation.height
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                    if scale > 1 {
                                        scale = 1
                                        offset = .zero
                                    } else {
                                        scale = 2.5
                                    }
                                }
                            }
                    } else {
                        ContentUnavailableView("사진을 열 수 없습니다", systemImage: "photo")
                    }
                }
            }
            .navigationTitle(record.createdAt.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

/// Task 091 P1-3: one still in the library list.
///
/// A camera glyph rather than a thumbnail. Decoding a full-resolution still per row —
/// ~24MB each for a 4K capture — would make scrolling a full library a memory problem,
/// and the recording rows next to it show no thumbnail either, so a photo row with one
/// would read as a different kind of thing rather than a sibling.
struct PhotoRow: View {
    let photo: PhotoRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 16))
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(photo.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var detailLine: String {
        var parts: [String] = ["사진"]
        if photo.resolution.width > 0 {
            parts.append("\(Int(photo.resolution.width))×\(Int(photo.resolution.height))")
        }
        parts.append(ByteCountFormatter.string(fromByteCount: photo.fileSize, countStyle: .file))
        return parts.joined(separator: " · ")
    }
}
