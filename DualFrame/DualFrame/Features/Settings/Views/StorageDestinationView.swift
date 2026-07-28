//
//  StorageDestinationView.swift
//  DualFrame
//

import SwiftUI

/// Lets the user choose a default export destination and related preferences.
/// This screen only edits and persists `StorageSettings` — no export logic reads
/// these values yet.
struct StorageDestinationView: View {
    @StateObject private var viewModel = StorageSettingsViewModel()
    @ObservedObject var externalStorageViewModel: ExternalStorageViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Default Destination") {
                    ForEach(StorageDestination.allCases) { destination in
                        destinationRow(destination)
                    }
                }

                Section {
                    Toggle("Ask every time", isOn: $viewModel.settings.askEveryTime)
                    Toggle("Keep internal copy", isOn: $viewModel.settings.keepInternalCopy)
                }

                Section {
                    NavigationLink("Manage External Storage") {
                        ExternalStorageView(viewModel: externalStorageViewModel)
                    }
                }
            }
            .navigationTitle("Storage")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func destinationRow(_ destination: StorageDestination) -> some View {
        let available = isAvailable(destination)
        return Button {
            viewModel.settings.defaultDestination = destination
        } label: {
            HStack {
                Text(destination.title)
                    .foregroundStyle(available ? .primary : .secondary)
                if !available {
                    Text("(Disabled)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.settings.defaultDestination == destination {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(!available)
    }

    /// `externalDrive` is only selectable once a location has been connected via
    /// "Manage External Storage" — every other destination is always available.
    private func isAvailable(_ destination: StorageDestination) -> Bool {
        guard destination == .externalDrive else { return true }
        return externalStorageViewModel.device != nil
    }
}

#Preview {
    StorageDestinationView(externalStorageViewModel: ExternalStorageViewModel())
}
