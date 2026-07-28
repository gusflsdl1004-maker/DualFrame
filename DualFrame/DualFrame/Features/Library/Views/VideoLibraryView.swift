//
//  VideoLibraryView.swift
//  DualFrame
//

import SwiftUI

/// Lists every recording stored in the internal library, newest first, and lets the
/// user export any of them to Photos or to a connected external storage location.
/// The internal library file is never deleted by exporting — only user-initiated
/// deletion (swipe) removes it.
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
                        photosExportStatus: viewModel.exportStatus(for: record),
                        externalExportStatus: viewModel.externalExportStatus(for: record),
                        externalExportErrorMessage: viewModel.externalExportErrorMessages[record.id],
                        onExportToPhotos: { exportToPhotos(record) },
                        onExportToExternalStorage: { exportToExternalStorage(record) }
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
    }

    private func delete(at offsets: IndexSet) {
        let recordsToDelete = offsets.map { viewModel.records[$0] }
        Task {
            for record in recordsToDelete {
                await viewModel.delete(record)
            }
        }
    }

    private func exportToPhotos(_ record: VideoRecord) {
        Task {
            await viewModel.exportToPhotos(record)
        }
    }

    private func exportToExternalStorage(_ record: VideoRecord) {
        Task {
            await viewModel.exportToExternalStorage(record)
        }
    }
}

private struct VideoRecordRow: View {
    let record: VideoRecord
    let photosExportStatus: PhotoLibraryExportStatus
    let externalExportStatus: ExternalStorageExportStatus
    let externalExportErrorMessage: String?
    let onExportToPhotos: () -> Void
    let onExportToExternalStorage: () -> Void

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

            photosExportControl
            externalStorageExportControl
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var photosExportControl: some View {
        switch photosExportStatus {
        case .idle:
            Button("Export to Photos", action: onExportToPhotos)
                .font(.caption.bold())

        case .exporting:
            HStack(spacing: 6) {
                ProgressView()
                Text("Exporting...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .success:
            Label("Photos: Success", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)

        case .failed(let permissionDenied):
            VStack(alignment: .leading, spacing: 4) {
                Label("Photos: Failed", systemImage: "xmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)

                if permissionDenied {
                    Text("Photos access is required. Enable it in Settings to export.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Open Settings", action: openSettings)
                        .font(.caption2)
                } else {
                    Button("Retry", action: onExportToPhotos)
                        .font(.caption2)
                }
            }
        }
    }

    @ViewBuilder
    private var externalStorageExportControl: some View {
        switch externalExportStatus {
        case .idle:
            Button("Export to External Storage", action: onExportToExternalStorage)
                .font(.caption.bold())

        case .exporting:
            HStack(spacing: 6) {
                ProgressView()
                Text("Exporting...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .success:
            Label("External: Success", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)

        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Label("External: Failed", systemImage: "xmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                if let externalExportErrorMessage {
                    Text(externalExportErrorMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Retry", action: onExportToExternalStorage)
                    .font(.caption2)
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
