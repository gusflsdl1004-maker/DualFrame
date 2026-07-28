//
//  ExternalStorageView.swift
//  DualFrame
//

import SwiftUI
import UniformTypeIdentifiers

/// Lets the user pick an external storage location through the Files app and shows
/// its name, capacity, and connection status. No files are copied here — this only
/// detects and displays the location.
struct ExternalStorageView: View {
    @ObservedObject var viewModel: ExternalStorageViewModel
    @State private var isPickerPresented = false

    var body: some View {
        Form {
            Section("Connected Storage") {
                LabeledContent("Name", value: viewModel.device?.name ?? "—")
                LabeledContent("Available Space", value: formattedSpace(viewModel.device?.availableSpace))
                LabeledContent("Total Space", value: formattedSpace(viewModel.device?.totalSpace))
                LabeledContent("Status", value: statusText)
            }

            Section {
                Button("Choose Storage Location") {
                    isPickerPresented = true
                }
                if viewModel.device != nil {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnect()
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("External Storage")
        .fileImporter(isPresented: $isPickerPresented, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                viewModel.connect(to: url)
            case .failure:
                viewModel.disconnect()
            }
        }
    }

    private var statusText: String {
        switch viewModel.status {
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .unavailable: "Unavailable"
        }
    }

    private func formattedSpace(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    NavigationStack {
        ExternalStorageView(viewModel: ExternalStorageViewModel())
    }
}
