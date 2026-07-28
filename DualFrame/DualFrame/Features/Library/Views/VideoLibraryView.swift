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

    init(libraryService: InternalVideoLibraryService, externalStorageViewModel: ExternalStorageViewModel) {
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
                        RecordingGroupDetailView(group: group, viewModel: viewModel)
                    } label: {
                        RecordingGroupRow(group: group)
                    }
                }
                .onDelete(perform: deleteGroups)
            }
            .overlay {
                if viewModel.groups.isEmpty {
                    ContentUnavailableView("녹화된 영상이 없습니다", systemImage: "film")
                }
            }
            .navigationTitle("보관함")
        }
        .task {
            await viewModel.refresh()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(group.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "video.fill")
                .font(.headline)
            Text(formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
            memberStatusRow(title: "롱폼", member: group.long)
            memberStatusRow(title: "숏폼", member: group.short)
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
    @State private var previewingRecord: VideoRecord?

    var body: some View {
        List {
            memberSection(title: "롱폼", member: group.long)
            memberSection(title: "숏폼", member: group.short)
        }
        .navigationTitle(group.createdAt.formatted(date: .abbreviated, time: .shortened))
        .sheet(item: $previewingRecord) { record in
            VideoPlayer(player: AVPlayer(url: record.localURL))
                .ignoresSafeArea()
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
            Label("완료 (\(destination.title))", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)

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
