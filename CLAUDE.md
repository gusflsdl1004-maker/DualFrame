# CLAUDE

## DualFrame Development Principles

These are the priority order and constraints for all DualFrame engineering work. When trade-offs come up, resolve them in this order.

1. Never lose recorded video.
2. Recording stability is more important than UI.
3. Recording stability is more important than visual effects.
4. Save safely before adding new features.
5. Battery and storage awareness are required.
6. The app must survive interruptions whenever possible (phone calls, backgrounding, low storage, low battery, thermal state).
7. Memory usage should remain predictable during long recordings — no unbounded growth.
8. Every new feature must be verified with a successful build.

## Additional Development Rules

1. Never sacrifice recording stability for new features.
2. Test every camera-related feature on a real iPhone whenever possible.
3. Simulator verification alone is not sufficient for camera functionality.
4. Every completed task must include: Successful Build, Successful Git Commit, Successful Git Push, Updated Project Status Report, Updated Real Device Test Report, Updated Performance Report, Updated Battery & Thermal Report.
5. Never implement multiple major features in a single task.
6. Keep exactly one Git commit per completed task.
7. If a feature cannot be fully verified in the Simulator, clearly explain why and identify exactly what must be tested on a physical device.
8. Before implementing a new feature, verify that all previously completed features still build and function correctly.
9. Measure performance whenever recording-related code changes.
10. Report any increase in memory usage, CPU usage, dropped frames, or disk write latency compared to the previous task.
11. Never reduce recording quality or stability for the sake of performance optimization without clearly documenting the trade-off.
12. If performance cannot be measured in the current environment, explicitly state why and describe how it should be verified on a real iPhone.
13. Evaluate battery consumption and thermal impact whenever recording-related code changes.
14. Never increase CPU usage significantly without documenting the reason.
15. If a feature increases battery drain or device temperature, report the trade-offs and possible optimizations.
16. If battery or thermal behavior cannot be measured in the current environment, explicitly state why and describe how to verify it on a real iPhone.
17. Compare battery, thermal, memory, and CPU metrics against the previous completed task whenever possible.
18. If a new feature may affect long-duration recording stability, explicitly analyze the risks before marking the task as complete.
19. Never risk losing a recorded video for the sake of performance, UI responsiveness, or feature convenience.
20. Every task that modifies recording, saving, exporting, or file management must include a failure-path review describing what happens if the app crashes, the device powers off, storage becomes full, or permissions change during the operation.
21. Every recording-related task must preserve a clear path toward future crash recovery.
22. Never introduce architecture that makes interrupted recordings unrecoverable.
23. Any new recording component should define where recovery checkpoints could be added in future tasks.
24. If recovery cannot yet be implemented, explicitly document what state would be required to restore an interrupted recording.
25. Every checkpoint written to disk must use an atomic write operation whenever possible.
26. Never overwrite recovery metadata without validating the previous checkpoint.
27. Always verify that recovery metadata and recording files remain consistent.
28. If checkpoint data becomes invalid or corrupted, detect it gracefully and report the issue instead of crashing.
29. Never automatically delete temporary recording files unless their final recording has been successfully validated.
30. Every recovery-related task must explicitly document what user data could still be lost in the current implementation.
31. Every interruption-related task must document iOS system behavior separately from application behavior.
32. Never assume Simulator behavior matches real iPhone behavior for camera, audio, interruptions, or background execution.
33. Clearly distinguish between "verified on Simulator", "verified on real device", and "not yet verified".
34. If a feature depends on iOS lifecycle events, explicitly document which UIApplication or UIScene lifecycle states were considered.
35. Every interruption event must preserve the current recording state before releasing recording resources.
36. Never assume that recording can safely continue after an interruption.
37. Clearly distinguish between interruption detection, interruption handling, and interruption recovery.
38. If interruption behavior cannot be verified in Simulator, explicitly document which scenarios require real-device testing.

## Report Templates

Every completed task's final message must include these four reports (in addition to the file-by-file explanation the task itself asks for).

**Battery & Thermal Report**
- Battery Consumption:
- Device Temperature:
- Thermal State:
- Recording Time Until Thermal Warning:
- Battery Drain Per 10 Minutes:
- Known Thermal Risks:
- Optimization Suggestions:

**Performance Report**
- Recording Resolution:
- Recording FPS:
- Memory Usage:
- CPU Usage:
- Dropped Frames:
- Average Write Time:
- Disk Write Speed:
- Known Performance Risks:
- Optimization Suggestions:

**Real Device Test**
- Device:
- iOS Version:
- Recording Quality Tested:
- Recording FPS Tested:
- Recording Duration:
- Photos Export Tested:
- External Storage Tested:
- Battery Consumption:
- Thermal State:
- Test Result:
- Known Device Issues:
- Simulator Result:
- Real Device Result:

**Project Status Report**
- Current Task:
- Current Milestone:
- Overall Progress (%):
- Build Status:
- Files Changed:
- Git Commit Hash:
- Git Commit Message:
- Git Push Status:
- Known Issues:
- Next Recommended Task:

**Recovery Readiness Report** (include whenever a task touches the recording pipeline, per rules 21-24)
- Current Recovery Points:
- Last Safe Recording State:
- Temporary File Integrity:
- Recording Session Status:
- Recovery Extension Points:
- Crash Recovery Readiness:
- Known Recovery Risks:
- Recommended Improvements:

**Data Integrity Report** (include whenever a task touches checkpoint or recording file persistence, per rules 25-30)
- Checkpoint Write Success:
- Checkpoint Read Success:
- Atomic File Write:
- Temporary File Verified:
- Final File Verified:
- Recovery Metadata Valid:
- Known Data Integrity Risks:
- Recommended Improvements:

**Platform Behavior Report** (include whenever a task touches interruptions, lifecycle events, or permissions, per rules 31-34)
- Phone Call Interruption:
- Lock Screen Behavior:
- Home Button / App Switch:
- Background Transition:
- Camera Permission Change:
- Microphone Permission Change:
- Storage Full Behavior:
- Low Power Mode Behavior:
- Known Platform Risks:
- Recommended Improvements:

Every field in this report must be marked "verified on Simulator", "verified on real device", or "not yet verified" (rule 33) — never assume Simulator behavior generalizes to a real iPhone for any of these (rule 32). If a row depends on a specific `UIApplication`/`UIScene` lifecycle event, name it explicitly (rule 34).

**Interruption Report** (include whenever a task touches `AVCaptureSession`/`AVAudioSession` interruption handling, per rules 35-38)
- Interruption Source:
- Checkpoint Saved Before Interruption:
- Recording Stopped Safely:
- Recording Corrupted:
- User Notification Shown:
- Resume Available:
- Known Interruption Risks:
- Recommended Improvements:

No physical iPhone is available in this environment, and Simulator cannot report real battery/thermal/CPU/memory metrics for camera hardware that doesn't exist there. Every Battery & Thermal Report, Performance Report, and Real Device Test must state this plainly, mark device-dependent fields as untested rather than guessing or fabricating values, and describe exactly what the user needs to measure on real hardware (per rules 12 and 16 above). Every task touching recording/saving/exporting/file management must also include a short failure-path review (rule 20): what happens on crash, sudden power-off, full storage, or a permission change mid-operation.
