//
//  RecordingDebugView.swift
//  DualFrame
//

#if DEBUG
import SwiftUI

/// Diagnostics & Developer Panel (Task 026) — a debug-only diagnostics screen showing
/// live internal recording state, so a physical device can be checked at a glance
/// without attaching a debugger. The entire file is wrapped in `#if DEBUG`, so none of
/// it — including this type itself — is compiled into a Release build; there is no
/// runtime check to bypass, only a build-time one.
///
/// Read-only: nothing here can start, stop, or otherwise affect a recording. It only
/// observes already-published values (`RecordingViewModel`/`OrientationManager`/
/// `RecordingModeViewModel`) and reads two already-public, unmodified methods —
/// `RecordingCheckpointStore.load()` (the same one `RecoveryViewModel` already uses)
/// and `RecordingPerformanceMonitor.currentAvailableStorageBytes()` — so this adds no
/// new Recovery/PerformanceMonitor code, only new display.
struct RecordingDebugView: View {
    @ObservedObject var recordingViewModel: RecordingViewModel
    @ObservedObject var orientationManager: OrientationManager
    @ObservedObject var recordingModeViewModel: RecordingModeViewModel
    let activeQuality: RecordingQuality?
    let activeFPS: RecordingFPS?
    let dualRecordingCoordinator: DualRecordingCoordinator

    @State private var lastCheckpointSavedAt: Date?
    @State private var storageRemainingText = "--"
    @State private var activeOutputProfilesText = "--"

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    LabeledContent("Session ID", value: recordingViewModel.currentSessionID?.uuidString ?? "--")
                    LabeledContent("Recording Mode", value: recordingModeViewModel.settings.mode.title)
                    LabeledContent("Recording State", value: recordingViewModel.displayStatusText)
                    LabeledContent("Active Output Profiles", value: activeOutputProfilesText)
                }

                Section("Writers") {
                    LabeledContent("Long Writer Status", value: recordingViewModel.longFormStatusText ?? "--")
                    LabeledContent("Short Writer Status", value: recordingViewModel.shortFormStatusText ?? "--")
                }

                Section("Capture") {
                    LabeledContent("Orientation", value: orientationLabel)
                    LabeledContent(
                        "Resolution",
                        value: activeQuality.map { "\($0.dimensions.width)×\($0.dimensions.height)" } ?? "--"
                    )
                    LabeledContent("FPS", value: activeFPS?.title ?? "--")
                }

                Section("Recovery") {
                    LabeledContent(
                        "Checkpoint Time",
                        value: lastCheckpointSavedAt?.formatted(date: .omitted, time: .standard) ?? "--"
                    )
                }

                Section("Performance") {
                    LabeledContent("Memory Usage", value: recordingViewModel.memoryStatusText)
                    LabeledContent("Dropped Frames", value: recordingViewModel.formattedDroppedFrames)
                    LabeledContent("Write Latency", value: recordingViewModel.writeStatusText)
                    LabeledContent("Storage Remaining", value: storageRemainingText)
                }

                Section {
                    LabeledContent("Export Status", value: "Not tracked here — see Library")
                } footer: {
                    Text("Export state is tracked per-recording in the Library screen, not at the session level this panel observes.")
                }
            }
            .navigationTitle("Debug Verification")
        }
        .task {
            while !Task.isCancelled {
                await refreshCheckpointTimestamp()
                await refreshStorageRemaining()
                await refreshActiveOutputProfiles()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var orientationLabel: String {
        switch orientationManager.deviceOrientation {
        case .portrait: "Portrait"
        case .portraitUpsideDown: "Portrait Upside Down"
        case .landscapeLeft: "Landscape Left"
        case .landscapeRight: "Landscape Right"
        }
    }

    /// Derives "when was the checkpoint last saved" purely from
    /// `RecordingCheckpoint`'s own existing fields (`recordingStartTime +
    /// recordingDuration`, since the checkpoint payload has no separate "saved at"
    /// field of its own) via the already-public, unmodified
    /// `RecordingCheckpointStore.load()` — no new Recovery/Checkpoint code.
    private func refreshCheckpointTimestamp() async {
        guard let checkpoint = await dualRecordingCoordinator.recordingService.checkpointStore.load() else {
            lastCheckpointSavedAt = nil
            return
        }
        lastCheckpointSavedAt = checkpoint.recordingStartTime.addingTimeInterval(checkpoint.recordingDuration)
    }

    private func refreshStorageRemaining() async {
        guard let bytes = await dualRecordingCoordinator.recordingService.performanceMonitor.currentAvailableStorageBytes() else {
            storageRemainingText = "--"
            return
        }
        storageRemainingText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshActiveOutputProfiles() async {
        let profiles = await dualRecordingCoordinator.activeProfiles
        activeOutputProfilesText = profiles.map(\.outputName).joined(separator: ", ")
    }
}
#endif
