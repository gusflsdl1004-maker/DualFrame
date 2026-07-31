//
//  VideoLibraryView.swift
//  DualFrame
//

import AVKit
import SwiftUI

/// Lists every recording stored in the internal library, grouped into recording
/// sessions (Task 023) — a `.single`-mode session shows one video, a `.dual`-mode
/// session shows its long-form and short-form outputs together, each with its own
/// success/failure status. Tapping a group opens per-output preview/export.
///
/// The internal library file is only removed if the user explicitly confirms
/// deletion after a successful export (when "keep internal copy" is off), swipes to
/// delete a whole group, or deletes one output individually from the group's detail
/// screen — exporting never removes it automatically.
struct VideoLibraryView: View {
    @StateObject private var viewModel: VideoLibraryViewModel
    /// Task 090 P1-1: the delete-everything confirmation.
    @State private var isConfirmingDeleteAll = false
    /// Task 091 P1-4: the still currently open full-screen.
    @State private var previewingPhoto: PhotoRecord?

    /// Task 070 requirement 5/6: nil in previews and any caller that does not have the
    /// app-root coordinator; the badge simply does not appear then.
    private var shortGenerationCoordinator: ShortGenerationCoordinator?

    init(
        libraryService: InternalVideoLibraryService,
        externalStorageViewModel: ExternalStorageViewModel,
        shortGenerationCoordinator: ShortGenerationCoordinator? = nil
    ) {
        self.shortGenerationCoordinator = shortGenerationCoordinator
        _viewModel = StateObject(wrappedValue: VideoLibraryViewModel(
            libraryService: libraryService,
            externalStorageViewModel: externalStorageViewModel
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.groups) { group in
                    NavigationLink {
                        RecordingGroupDetailView(
                            group: group,
                            viewModel: viewModel,
                            shortGenerationCoordinator: shortGenerationCoordinator
                        )
                    } label: {
                        RecordingGroupRow(
                            group: group,
                            isGeneratingShort: shortGenerationCoordinator?
                                .isGenerating(forGroupID: group.id) ?? false
                        )
                    }
                }
                .onDelete(perform: deleteGroups)

                // Task 091 P1-3: stills, in their own section rather than interleaved.
                // Recordings carry group state, generation progress and export state that
                // a still has none of, so a single mixed list would have had two kinds of
                // row pretending to be one kind. A section keeps both honest and still
                // reads as one library.
                if !viewModel.photos.isEmpty {
                    Section("사진") {
                        ForEach(viewModel.photos) { photo in
                            Button {
                                previewingPhoto = photo
                            } label: {
                                PhotoRow(photo: photo)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deletePhotos)
                    }
                }
            }
            .overlay {
                if viewModel.groups.isEmpty && viewModel.photos.isEmpty {
                    ContentUnavailableView("보관함이 비어 있습니다", systemImage: "photo.on.rectangle")
                }
            }
            .navigationTitle("보관함")
            .toolbar {
                // Task 090 P1-1. Hidden when there is nothing to delete, so the most
                // destructive control in the app is not sitting there permanently
                // one tap from an empty confirmation.
                if !viewModel.groups.isEmpty || !viewModel.photos.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("전체 삭제", role: .destructive) {
                            isConfirmingDeleteAll = true
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .task {
            await viewModel.refresh()
        }
        .fullScreenCover(item: $previewingPhoto) { photo in
            PhotoViewerView(record: photo)
        }
        .alert("앱 내 보관함을 모두 삭제할까요?", isPresented: $isConfirmingDeleteAll) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) {
                Task { await viewModel.deleteAll() }
            }
        } message: {
            // Says what survives, not just what goes. The whole reason this is safe to
            // offer is that an exported copy is a separate file owned by Photos, and the
            // user has to know that before tapping 삭제 — afterwards is too late.
            Text("앱 내부에 저장된 영상과 메타데이터가 모두 삭제되고 저장 공간이 확보됩니다. 되돌릴 수 없습니다.\n\n사진 앱으로 이미 내보낸 사본은 삭제되지 않습니다.")
        }
        .confirmationDialog(
            "저장 위치 선택",
            isPresented: destinationPickerBinding,
            titleVisibility: .visible
        ) {
            ForEach(viewModel.pendingDestinationChoices ?? []) { destination in
                Button(destination.title) {
                    viewModel.resolveDestinationChoice(destination)
                }
            }
            Button("취소", role: .cancel) {
                viewModel.resolveDestinationChoice(nil)
            }
        }
        .confirmationDialog(
            "내부 보관함에서도 삭제할까요?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                viewModel.resolveDeleteConfirmation(true)
            }
            Button("보관", role: .cancel) {
                viewModel.resolveDeleteConfirmation(false)
            }
        } message: {
            Text("내보내기가 완료되었습니다. 내부 보관함에 있는 사본을 삭제할까요?")
        }
    }

    /// Wraps `pendingDestinationChoices` so any dismissal — a button tap or the
    /// user swiping the dialog away — always resolves the coordinator's prompt.
    private var destinationPickerBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDestinationChoices != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.resolveDestinationChoice(nil)
                }
            }
        )
    }

    /// Same reasoning as `destinationPickerBinding`, for the delete-confirmation prompt.
    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isConfirmingDelete },
            set: { isPresented in
                if !isPresented {
                    viewModel.resolveDeleteConfirmation(false)
                }
            }
        )
    }

    /// Task 091 P1-3: swipe-to-delete for stills, matching recordings.
    private func deletePhotos(at offsets: IndexSet) {
        let photosToDelete = offsets.map { viewModel.photos[$0] }
        Task {
            for photo in photosToDelete {
                await viewModel.delete(photo)
            }
        }
    }

    /// Requirement 7: group-level deletion — removes every output in the group plus
    /// the group's own metadata.
    private func deleteGroups(at offsets: IndexSet) {
        let groupsToDelete = offsets.map { viewModel.groups[$0] }
        Task {
            for group in groupsToDelete {
                await viewModel.delete(group)
            }
        }
    }
}

/// One row in the grouped library list — requirement 4's "🎥 Recording / date / Long-form ✅ / Short-form ✅" layout.
private struct RecordingGroupRow: View {
    let group: ResolvedRecordingGroup
    /// Requirement 5: shown instead of the short-form status while a post-processing
    /// job for this recording is still running, so an absent short-form output reads as
    /// "being made" rather than "missing".
    let isGeneratingShort: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(group.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "video.fill")
                .font(.headline)
            Text(formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
            memberStatusRow(title: "롱폼", member: group.long)
            if isGeneratingShort {
                Label("숏폼 — 생성 중", systemImage: "gearshape.arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            } else {
                // Requirement 6: once generation lands, the group gains its short-form
                // member and this reverts to the normal ready state automatically.
                memberStatusRow(title: "숏폼", member: group.displayedShort)
            }
        }
        .padding(.vertical, 4)
    }

    private var formattedDuration: String {
        let totalSeconds = Int(group.duration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    @ViewBuilder
    private func memberStatusRow(title: String, member: ResolvedRecordingGroupMember) -> some View {
        switch member {
        case .none:
            EmptyView()
        case .succeeded:
            Label(title, systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
        case .failed:
            Label("\(title) — 실패", systemImage: "xmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
        case .missing:
            Label("\(title) — 파일 없음", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Requirement 5: tapping a group opens this screen, where long-form and short-form
/// are each independently previewable and exportable (reusing `VideoRecordRow` and
/// `ExportCoordinator` unchanged — no new export logic).
private struct RecordingGroupDetailView: View {
    let group: ResolvedRecordingGroup
    @ObservedObject var viewModel: VideoLibraryViewModel
    /// Task 072 P1-7: so the export section can say "생성 중" rather than only greying
    /// out — a disabled button with no explanation reads as broken.
    var shortGenerationCoordinator: ShortGenerationCoordinator?
    @State private var previewingRecord: VideoRecord?

    private var isGeneratingShort: Bool {
        shortGenerationCoordinator?.isGenerating(forGroupID: group.id) ?? false
    }

    var body: some View {
        List {
            exportSection
            memberSection(title: "롱폼", member: group.long)
            memberSection(title: "숏폼", member: group.displayedShort)
        }
        .navigationTitle(group.createdAt.formatted(date: .abbreviated, time: .shortened))
        .sheet(item: $previewingRecord) { record in
            // Requirement 2: the generated short-form file is previewable in-app before
            // the user spends an ad on exporting it.
            VideoPlayer(player: AVPlayer(url: record.localURL))
                .ignoresSafeArea()
        }
        .alert(
            "저장",
            isPresented: Binding(
                get: { viewModel.lastExportMessage != nil },
                set: { if !$0 { viewModel.lastExportMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) { viewModel.lastExportMessage = nil }
        } message: {
            Text(viewModel.lastExportMessage ?? "")
        }
    }

    /// Task 071 requirement 5: the three export targets, as one action each.
    ///
    /// A target whose file does not exist yet is disabled rather than hidden — a
    /// short-form export that is merely still generating should read as "not ready",
    /// not as "not a feature".
    @ViewBuilder
    private var exportSection: some View {
        Section {
            ForEach(ExportTarget.allCases) { target in
                Button {
                    Task { await viewModel.export(target: target, group: group) }
                } label: {
                    HStack {
                        Label(target.title, systemImage: "square.and.arrow.up")
                        Spacer()
                        if viewModel.currentPlan == .free {
                            // Stated up front, not discovered after tapping.
                            Label("광고", systemImage: "play.rectangle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(viewModel.isPresentingAd || !isAvailable(target))
            }
        } header: {
            Text("카메라롤로 저장")
        } footer: {
            if isGeneratingShort {
                // P1-7: named explicitly, and it clears itself — the group gains its
                // short-form member when generation lands, so the disabled targets
                // become available without the user doing anything.
                Text("숏폼을 생성하는 중입니다. 완료되면 숏폼 저장이 자동으로 활성화됩니다.")
            } else if viewModel.isPresentingAd {
                Text("광고 재생 중…")
            } else if viewModel.currentPlan == .free {
                Text("무료 플랜은 광고를 끝까지 시청해야 저장됩니다. 광고가 실패하거나 도중에 닫으면 저장되지 않으며, 앱 내 영상은 그대로 유지됩니다.")
            } else {
                Text("Pro 플랜은 광고 없이 바로 저장됩니다.")
            }
        }
    }

    private func isAvailable(_ target: ExportTarget) -> Bool {
        switch target {
        case .longOnly: group.long.record != nil
        case .shortOnly: group.displayedShort.record != nil
        case .longAndShort: group.long.record != nil && group.displayedShort.record != nil
        }
    }

    @ViewBuilder
    private func memberSection(title: String, member: ResolvedRecordingGroupMember) -> some View {
        switch member {
        case .none:
            EmptyView()

        case .failed:
            Section(title) {
                Label("녹화 실패", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }

        case .missing:
            Section(title) {
                Label("파일을 찾을 수 없습니다", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }

        case .succeeded(let record):
            Section(title) {
                VideoRecordRow(
                    record: record,
                    exportState: viewModel.exportState(for: record),
                    onExport: { Task { await viewModel.export(record) } }
                )

                Button {
                    previewingRecord = record
                } label: {
                    Label("미리보기", systemImage: "play.circle")
                }

                Button(role: .destructive) {
                    Task { await viewModel.delete(record) }
                } label: {
                    Label("삭제", systemImage: "trash")
                }
            }
        }
    }
}

/// One output's export status and controls — unchanged since before Task 023, just
/// now reused inside `RecordingGroupDetailView` instead of a flat list.
struct VideoRecordRow: View {
    let record: VideoRecord
    let exportState: ExportState
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.filename)
                .font(.headline)
            Text("\(formattedDuration) · \(formattedResolution) · \(formattedFileSize)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(record.createdAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.secondary)

            exportControl
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var exportControl: some View {
        switch exportState {
        case .idle:
            Button("내보내기", action: onExport)
                .font(.caption.bold())

        case .exporting:
            HStack(spacing: 6) {
                ProgressView()
                Text("내보내는 중...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .success(let destination):
            // Task 043 requirement 2: the actual export flow (ExportCoordinator and
            // the underlying Photos/external-storage services) was always safely
            // re-runnable — this state simply never offered a control to run it
            // again, unlike .idle/.failed below. Without this button, a successful
            // export was a dead end: the same recording could never be exported a
            // second time from this screen.
            VStack(alignment: .leading, spacing: 4) {
                Label("완료 (\(destination.title))", systemImage: "checkmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                Button("다시 내보내기", action: onExport)
                    .font(.caption2)
            }

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("실패", systemImage: "xmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)

                if reason == .photosPermissionDenied {
                    Text("사진 접근 권한이 필요합니다. 설정에서 권한을 허용한 뒤 다시 시도해 주세요.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("설정으로 이동", action: openSettings)
                        .font(.caption2)
                } else {
                    Button("다시 시도", action: onExport)
                        .font(.caption2)
                }
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var formattedDuration: String {
        let totalSeconds = Int(record.duration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private var formattedResolution: String {
        "\(Int(record.resolution.width))×\(Int(record.resolution.height))"
    }

    private var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file)
    }
}

#Preview {
    VideoLibraryView(
        libraryService: InternalVideoLibraryService(),
        externalStorageViewModel: ExternalStorageViewModel()
    )
}
