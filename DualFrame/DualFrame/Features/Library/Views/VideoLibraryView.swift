//
//  VideoLibraryView.swift
//  DualFrame
//

import SwiftUI

/// Lists every recording stored in the internal library, newest first, and lets the
/// user export any of them through the settings-driven `ExportCoordinator` flow.
/// The internal library file is only removed if the user explicitly confirms
/// deletion after a successful export (when "keep internal copy" is off) or swipes
/// to delete it directly — exporting never removes it automatically.
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
                ForEach(viewModel.records) { record in
                    VideoRecordRow(
                        record: record,
                        exportState: viewModel.exportState(for: record),
                        onExport: { export(record) }
                    )
                }
                .onDelete(perform: delete)
            }
            .overlay {
                if viewModel.records.isEmpty {
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

    private func delete(at offsets: IndexSet) {
        let recordsToDelete = offsets.map { viewModel.records[$0] }
        Task {
            for record in recordsToDelete {
                await viewModel.delete(record)
            }
        }
    }

    private func export(_ record: VideoRecord) {
        Task {
            await viewModel.export(record)
        }
    }
}

private struct VideoRecordRow: View {
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
