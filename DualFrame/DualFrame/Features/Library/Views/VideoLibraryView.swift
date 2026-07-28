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
                    ContentUnavailableView("No Recordings", systemImage: "film")
                }
            }
            .navigationTitle("Library")
        }
        .task {
            await viewModel.refresh()
        }
        .confirmationDialog(
            "Choose Destination",
            isPresented: destinationPickerBinding,
            titleVisibility: .visible
        ) {
            ForEach(viewModel.pendingDestinationChoices ?? []) { destination in
                Button(destination.title) {
                    viewModel.resolveDestinationChoice(destination)
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.resolveDestinationChoice(nil)
            }
        }
        .confirmationDialog(
            "Remove the internal copy?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                viewModel.resolveDeleteConfirmation(true)
            }
            Button("Keep", role: .cancel) {
                viewModel.resolveDeleteConfirmation(false)
            }
        } message: {
            Text("The video was exported successfully. Remove it from the internal library?")
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
            memberStatusRow(title: "Long-form", member: group.long)
            memberStatusRow(title: "Short-form", member: group.short)
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
            Label("\(title) — FAILED", systemImage: "xmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
        case .missing:
            Label("\(title) — unavailable", systemImage: "questionmark.circle")
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
            memberSection(title: "Long-form", member: group.long)
            memberSection(title: "Short-form", member: group.short)
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
                Label("Recording failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }

        case .missing:
            Section(title) {
                Label("File no longer available", systemImage: "questionmark.circle")
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
                    Label("Preview", systemImage: "play.circle")
                }

                Button(role: .destructive) {
                    Task { await viewModel.delete(record) }
                } label: {
                    Label("Delete", systemImage: "trash")
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
            Button("Export", action: onExport)
                .font(.caption.bold())

        case .exporting:
            HStack(spacing: 6) {
                ProgressView()
                Text("Exporting...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .success(let destination):
            Label("Success (\(destination.title))", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Failed", systemImage: "xmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)

                if reason == .photosPermissionDenied {
                    Text("Photos access is required. Enable it in Settings to export.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Open Settings", action: openSettings)
                        .font(.caption2)
                } else {
                    Button("Retry", action: onExport)
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
