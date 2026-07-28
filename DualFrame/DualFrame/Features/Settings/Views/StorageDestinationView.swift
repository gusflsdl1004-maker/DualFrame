//
//  StorageDestinationView.swift
//  DualFrame
//

import SwiftUI

/// The app's settings screen: default export destination and related preferences,
/// plus (since Task 013) recording quality. This screen only edits and persists
/// settings — it doesn't itself run export or recording logic.
struct StorageDestinationView: View {
    @StateObject private var viewModel = StorageSettingsViewModel()
    @StateObject private var recoveryViewModel = RecoveryViewModel(checkpointStore: RecordingCheckpointStore())
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

                Section("Recording") {
                    NavigationLink("Recording Quality") {
                        RecordingQualityView()
                    }
                    NavigationLink("Recording FPS") {
                        RecordingFPSView()
                    }
                    NavigationLink("Recording Mode") {
                        RecordingModeView()
                    }
                }

                Section("Recovery") {
                    recoveryStatusView
                }

                Section("Diagnostics") {
                    NavigationLink("Recording Sessions") {
                        DiagnosticsView()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await recoveryViewModel.checkRecoveryStatus()
        }
    }

    @ViewBuilder
    private var recoveryStatusView: some View {
        switch recoveryViewModel.status {
        case .checking:
            Text("Checking...")
                .foregroundStyle(.secondary)

        case .noRecoveryNeeded:
            Text("No Recovery Needed")
                .foregroundStyle(.secondary)

        case .recoveryAvailable:
            VStack(alignment: .leading, spacing: 4) {
                Text("Recovery Available")
                    .font(.headline)
                Text("Last Recording: \(recoveryViewModel.formattedTimestamp)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Duration: \(recoveryViewModel.formattedDuration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(recoveryViewModel.temporaryFileExists ? "File Exists" : "File Missing")
                    .font(.caption)
                    .foregroundStyle(recoveryViewModel.temporaryFileExists ? .green : .red)
            }

        case .corrupted:
            Text("Recovery data is corrupted")
                .foregroundStyle(.red)
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
