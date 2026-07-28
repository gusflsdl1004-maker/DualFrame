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
4. Every completed task must include: Successful Build, Successful Git Commit, Successful Git Push, Updated Project Status Report, Updated Real Device Test Report.
5. Never implement multiple major features in a single task.
6. Keep one Git commit per completed task.
7. If a feature cannot be fully verified in the Simulator, clearly document why and identify what must be tested on a physical device.
8. Before implementing a new feature, verify that all previously completed features still build and function correctly.
