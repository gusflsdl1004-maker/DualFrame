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
            Section("연결된 저장소") {
                LabeledContent("이름", value: viewModel.device?.name ?? "—")
                LabeledContent("사용 가능 공간", value: formattedSpace(viewModel.device?.availableSpace))
                LabeledContent("전체 공간", value: formattedSpace(viewModel.device?.totalSpace))
                LabeledContent("상태", value: statusText)
            }

            Section {
                Button("저장 위치 선택") {
                    isPickerPresented = true
                }
                if viewModel.device != nil {
                    Button("연결 해제", role: .destructive) {
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
        .navigationTitle("외장 저장소")
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
        case .connected: "연결됨"
        case .disconnected: "연결 안 됨"
        case .unavailable: "사용 불가"
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
