//
//  VideoLibraryView.swift
//  DualFrame
//

import SwiftUI

/// Lists every recording stored in the internal library, newest first, and lets the
/// user export any of them to Photos. The internal library file is never deleted by
/// exporting — only user-initiated deletion (swipe) removes it.
struct VideoLibraryView: View {
    @StateObject private var viewModel: VideoLibraryViewModel

    init(libraryService: InternalVideoLibraryService) {
        _viewModel = StateObject(wrappedValue: VideoLibraryViewModel(libraryService: libraryService))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.records) { record in
                    VideoRecordRow(
                        record: record,
                        exportStatus: viewModel.exportStatus(for: record),
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
            await viewModel.exportToPhotos(record)
        }
    }
}

private struct VideoRecordRow: View {
    let record: VideoRecord
    let exportStatus: PhotoLibraryExportStatus
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
        switch exportStatus {
        case .idle:
            Button("Export to Photos", action: onExport)
                .font(.caption.bold())

        case .exporting:
            HStack(spacing: 6) {
                ProgressView()
                Text("Exporting...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .success:
            Label("Success", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)

        case .failed(let permissionDenied):
            VStack(alignment: .leading, spacing: 4) {
                Label("Failed", systemImage: "xmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)

                if permissionDenied {
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
    VideoLibraryView(libraryService: InternalVideoLibraryService())
}
