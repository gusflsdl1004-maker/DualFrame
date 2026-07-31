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

    /// Task 093 P0-2: guards the save button against a second tap. Set synchronously in
    /// the button action, before any await exists to suspend at — the same shape as the
    /// shutter guard, and for the same reason.
    @State private var isSaving = false
    @State private var toastMessage: String?
    @State private var saveErrorMessage: String?
    /// Task 094: flipped locally after a successful save so the panel updates without a
    /// gallery reload — the record itself is a value type and cannot change under us.
    @State private var didSaveToPhotos = false
    #if DEBUG
    /// Task 094: the detail panel is Debug-only and collapsed by default. It is a QA tool,
    /// and it covers the photo it is describing.
    @State private var showsDebugInfo = false
    #endif
    private let photosExportService = PhotoLibraryExportService()
    private let photoLibraryService = InternalPhotoLibraryService()

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

                    // Task 093 P2-1 and P0-1: what this photo is, and the one action for
                    // it. Kept at the bottom over the image rather than in the toolbar, so
                    // the image itself gets the whole screen while zooming.
                    VStack {
                        Spacer()
                        if let toastMessage {
                            Text(toastMessage)
                                .font(.footnote)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.7), in: Capsule())
                                .padding(.bottom, 8)
                                .transition(.opacity)
                        }
                        #if DEBUG
                        if showsDebugInfo { debugPanel }
                        #endif
                        infoPanel
                        saveButton
                    }
                    .padding(.bottom, 24)
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle(record.createdAt.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showsDebugInfo.toggle()
                    } label: {
                        Image(systemName: showsDebugInfo ? "ladybug.fill" : "ladybug")
                    }
                    .accessibilityLabel("디버그 정보")
                }
                #endif
            }
            .alert("사진 앱에 저장하지 못했습니다", isPresented: saveErrorBinding) {
                Button("확인", role: .cancel) { saveErrorMessage = nil }
            } message: {
                Text(saveErrorMessage ?? "")
            }
        }
    }

    /// Task 093 P0-1: same job and same wording as the video export button, so the two
    /// read as one feature rather than two.
    private var saveButton: some View {
        Button {
            guard !isSaving else { return }
            isSaving = true
            Task { await saveToPhotos() }
        } label: {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
                Text(isSaving ? "저장 중…" : "사진 앱에 저장")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(.tint, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    /// Task 093 P2-1. Resolution, size and capture time come from `PhotoRecord`; the
    /// quality label is read from the file rather than stored, see `qualityLabel`.
    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            infoRow("화질", qualityLabel)
            if record.resolution.width > 0 {
                infoRow("해상도", "\(Int(record.resolution.width)) × \(Int(record.resolution.height))")
            }
            infoRow("파일 크기", ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
            infoRow("촬영 시간", record.createdAt.formatted(date: .abbreviated, time: .standard))
            if let position = record.cameraPosition {
                infoRow("카메라", position == .front ? "전면" : "후면")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 10)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    /// Derived from the file, not stored on the record.
    ///
    /// The quality *setting* at capture time is not the same thing as what the file turned
    /// out to be — a device without HEIF support produces a JPEG on 고화질, and a format
    /// change can cap 최고화질. Reporting the container and whether the still is at the
    /// sensor's larger size describes the photo in hand, which is what the user is looking
    /// at. Storing the setting would have meant showing a label the file might contradict.
    private var qualityLabel: String {
        let container = record.localURL.pathExtension.lowercased() == "heic" ? "HEIF" : "JPEG"
        let megapixels = record.resolution.width * record.resolution.height / 1_000_000
        guard megapixels > 0 else { return container }
        return String(format: "%@ · %.1fMP", container, megapixels)
    }

    #if DEBUG
    /// Task 094: everything needed to judge whether a capture setting did what it claimed.
    ///
    /// The pairs are the point. Requested quality next to the container it produced says
    /// whether 고화질 actually got HEIF or fell back; container resolution next to EXIF
    /// resolution says whether the two agree, which they do not always. A single "quality"
    /// row would hide exactly the discrepancies this panel exists to find.
    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("DEBUG")
                .font(.caption2.bold())
                .foregroundStyle(.yellow)
            infoRow("저장 포맷", containerFormat)
            infoRow("요청 화질", record.captureQuality?.title ?? "기록 없음")
            infoRow("실제 해상도", formatted(record.resolution))
            infoRow("EXIF 해상도", record.exifResolution.map(formatted) ?? "없음")
            infoRow("파일 크기", "\(record.fileSize.formatted()) B")
            infoRow("촬영 카메라", record.cameraPosition.map { $0 == .front ? "전면" : "후면" } ?? "기록 없음")
            infoRow("저장 위치", storageLocation)
            infoRow("파일명", record.filename)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 10)
    }

    private func formatted(_ size: CGSize) -> String {
        size.width > 0 ? "\(Int(size.width)) × \(Int(size.height))" : "없음"
    }

    /// Read from the container, not from the requested setting — a device without HEIF
    /// support produces JPEG on 고화질, and that gap is what this row is for.
    private var containerFormat: String {
        record.localURL.pathExtension.lowercased() == "heic" ? "HEIF (.heic)" : "JPEG (.jpg)"
    }

    private var storageLocation: String {
        let inPhotos = didSaveToPhotos || (record.savedToPhotos ?? false)
        if record.savedToPhotos == nil && !didSaveToPhotos { return "앱 내부 (사진 앱 기록 없음)" }
        return inPhotos ? "앱 내부 + 사진 앱" : "앱 내부"
    }
    #endif

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )
    }

    /// Task 093 P0-3. The app's own copy is never touched — Photos gets a separate copy,
    /// so a failure here costs a message and nothing else.
    private func saveToPhotos() async {
        defer { isSaving = false }
        do {
            try await photosExportService.exportPhoto(at: record.localURL)
            await photoLibraryService.markSavedToPhotos(record)
            didSaveToPhotos = true
            showToast("사진이 사진 앱에 저장되었습니다.")
        } catch PhotoLibraryExportError.permissionDenied {
            saveErrorMessage = "사진 앱 접근 권한이 없습니다. 설정에서 권한을 허용해 주세요."
        } catch {
            saveErrorMessage = "저장에 실패했습니다. 잠시 후 다시 시도해 주세요."
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toastMessage = nil }
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
