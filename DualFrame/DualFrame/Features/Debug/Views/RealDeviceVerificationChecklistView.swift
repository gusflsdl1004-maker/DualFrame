//
//  RealDeviceVerificationChecklistView.swift
//  DualFrame
//

#if DEBUG
import SwiftUI

/// Real Device Verification checklist (Task 031 requirement 1) — every item here can
/// only be meaningfully confirmed on a physical iPhone; Simulator has no camera. This
/// view only lets a tester check items off as they verify them on-device — it never
/// runs a check itself and never touches recording state. Debug builds only.
struct RealDeviceVerificationChecklistView: View {
    private let service = RealDeviceVerificationChecklistService()

    @State private var checkedState: [RealDeviceVerificationItem: Bool] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(RealDeviceVerificationItem.allCases) { item in
                        Toggle(item.title, isOn: binding(for: item))
                    }
                } footer: {
                    Text("실제 iPhone에서 확인한 항목만 체크하세요. 시뮬레이터는 카메라가 없어 검증할 수 없습니다.")
                }
            }
            .navigationTitle("실기기 점검 목록")
        }
        .onAppear {
            checkedState = service.load()
        }
    }

    private func binding(for item: RealDeviceVerificationItem) -> Binding<Bool> {
        Binding(
            get: { checkedState[item] ?? false },
            set: { newValue in
                checkedState[item] = newValue
                service.setChecked(newValue, for: item)
            }
        )
    }
}
#endif
