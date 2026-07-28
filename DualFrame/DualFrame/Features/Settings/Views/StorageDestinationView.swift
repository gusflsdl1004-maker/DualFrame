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
                Section("기본 저장 위치") {
                    ForEach(StorageDestination.allCases) { destination in
                        destinationRow(destination)
                    }
                }

                Section {
                    Toggle("매번 물어보기", isOn: $viewModel.settings.askEveryTime)
                    Toggle("내부 보관함에도 보관", isOn: $viewModel.settings.keepInternalCopy)
                }

                Section {
                    NavigationLink("외장 저장소 관리") {
                        ExternalStorageView(viewModel: externalStorageViewModel)
                    }
                }

                Section("녹화") {
                    NavigationLink("녹화 화질") {
                        RecordingQualityView()
                    }
                    NavigationLink("녹화 프레임레이트") {
                        RecordingFPSView()
                    }
                    NavigationLink("녹화 모드") {
                        RecordingModeView()
                    }
                }

                Section("복구") {
                    recoveryStatusView
                }

                Section("진단") {
                    NavigationLink("녹화 세션 기록") {
                        DiagnosticsView()
                    }
                }
            }
            .navigationTitle("설정")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
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
            Text("확인 중...")
                .foregroundStyle(.secondary)

        case .noRecoveryNeeded:
            Text("복구할 항목 없음")
                .foregroundStyle(.secondary)

        case .recoveryAvailable:
            VStack(alignment: .leading, spacing: 4) {
                Text("복구 가능한 녹화가 있습니다")
                    .font(.headline)
                Text("마지막 녹화: \(recoveryViewModel.formattedTimestamp)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("길이: \(recoveryViewModel.formattedDuration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(recoveryViewModel.temporaryFileExists ? "파일 있음" : "파일 없음")
                    .font(.caption)
                    .foregroundStyle(recoveryViewModel.temporaryFileExists ? .green : .red)
            }

        case .corrupted:
            Text("복구 데이터가 손상되었습니다")
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
                    Text("(사용 불가)")
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
