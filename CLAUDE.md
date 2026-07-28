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
