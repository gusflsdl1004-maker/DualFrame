//
//  VideoLibraryView.swift
//  DualFrame
//

import SwiftUI

/// Lists every recording stored in the internal library, newest first.
/// No export, Photos saving, or external storage happens here.
struct VideoLibraryView: View {
    @StateObject private var viewModel: VideoLibraryViewModel

    init(libraryService: InternalVideoLibraryService) {
        _viewModel = StateObject(wrappedValue: VideoLibraryViewModel(libraryService: libraryService))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.records) { record in
                    VideoRecordRow(record: record)
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
}

private struct VideoRecordRow: View {
    let record: VideoRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.filename)
                .font(.headline)
            Text("\(formattedDuration) · \(formattedResolution) · \(formattedFileSize)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(record.createdAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
