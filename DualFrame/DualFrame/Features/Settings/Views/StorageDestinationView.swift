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
        Button {
            viewModel.settings.defaultDestination = destination
        } label: {
            HStack {
                Text(destination.title)
                    .foregroundStyle(destination.isAvailable ? .primary : .secondary)
                if !destination.isAvailable {
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
        .disabled(!destination.isAvailable)
    }
}

#Preview {
    StorageDestinationView()
}
