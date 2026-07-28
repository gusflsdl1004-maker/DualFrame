//
//  RecordingDebugView.swift
//  DualFrame
//

#if DEBUG
import SwiftUI

/// Real Device Verification Mode (Task 026) — a debug-only diagnostics screen showing
/// live internal recording state, so a physical device can be checked at a glance
/// without attaching a debugger. The entire file is wrapped in `#if DEBUG`, so none of
/// it — including this type itself — is compiled into a Release build; there is no
/// runtime check to bypass, only a build-time one.
///
/// Read-only: nothing here can start, stop, or otherwise affect a recording. It only
/// observes `RecordingViewModel`/`OrientationManager` (already-published values) and
/// reads `RecordingCheckpointStore.load()` once a second — the same public, unmodified
/// method `RecoveryViewModel` already uses, so this adds no new Recovery code.
struct RecordingDebugView: View {
    @ObservedObject var recordingViewModel: RecordingViewModel
    @ObservedObject var orientationManager: OrientationManager
    let activeQuality: RecordingQuality?
    let activeFPS: RecordingFPS?
    let dualRecordingCoordinator: DualRecordingCoordinator

    @State private var lastCheckpointSavedAt: Date?

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    LabeledContent("Session ID", value: recordingViewModel.currentSessionID?.uuidString ?? "--")
                    LabeledContent("Recording State", value: recordingViewModel.statusText)
                }

                Section("Writers") {
                    LabeledContent("Current Writer", value: recordingViewModel.statusText)
                    LabeledContent("Long-form Writer", value: recordingViewModel.longFormStatusText ?? "--")
                    LabeledContent("Short-form Writer", value: recordingViewModel.shortFormStatusText ?? "--")
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
                        "Last Checkpoint Saved",
                        value: lastCheckpointSavedAt?.formatted(date: .omitted, time: .standard) ?? "--"
                    )
                }

                Section("Performance") {
                    LabeledContent("Memory", value: recordingViewModel.memoryStatusText)
                    LabeledContent("Dropped Frames", value: recordingViewModel.formattedDroppedFrames)
                    LabeledContent("Write Latency", value: recordingViewModel.writeStatusText)
                }
            }
            .navigationTitle("Debug Verification")
        }
        .task {
            while !Task.isCancelled {
                await refreshCheckpointTimestamp()
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
}
#endif
