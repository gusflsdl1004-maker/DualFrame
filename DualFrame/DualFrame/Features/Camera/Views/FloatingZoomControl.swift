//
//  FloatingZoomControl.swift
//  DualFrame
//

import SwiftUI

/// Task 076 #2: a circular zoom control that stays out of the way until it is needed.
///
/// Replaces the always-visible row of text buttons. That row cost permanent screen space
/// on a screen that now carries two live previews, and its width grew with the device's
/// lens count — the one place the UI should not vary by hardware is the space it
/// occupies.
///
/// Collapsed it is a single dot showing the current factor. Tapping expands the options
/// vertically; picking one collapses it again. Vertical rather than radial because the
/// column stays inside a thumb's arc on the right edge, which a ring does not — and
/// because the order (0.5 → 10) reads as a scale, which a circle destroys.
///
/// Pinch-to-zoom on the preview is untouched and remains the way to reach factors
/// between the stops, including beyond 5× where Task 073 stopped offering buttons.
struct FloatingZoomControl: View {
    let options: [CameraZoomOption]
    /// The raw factor currently applied, so the collapsed dot shows the truth even after
    /// a pinch left it between two stops.
    let currentFactor: CGFloat
    /// The factor the user reads as "1×" — not always 1.0 on a virtual multi-lens device.
    let baseFactor: CGFloat
    let onSelect: (CameraZoomOption) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 8) {
            if isExpanded {
                ForEach(options) { option in
                    dot(
                        label: option.label,
                        isActive: isActive(option),
                        action: {
                            onSelect(option)
                            collapse()
                        }
                    )
                    // Each stop fades and scales in, so the expansion reads as one
                    // gesture rather than a list appearing.
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            } else {
                dot(label: currentLabel, isActive: true, action: expand)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(6)
        .background(.black.opacity(isExpanded ? 0.35 : 0), in: Capsule())
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isExpanded)
    }

    private func expand() {
        isExpanded = true
    }

    private func collapse() {
        isExpanded = false
    }

    /// What the collapsed dot says. Derived from the live factor rather than from the
    /// last button tapped, so a pinch is reflected too — "1.7" instead of a stale "2".
    private var currentLabel: String {
        let relative = baseFactor > 0 ? currentFactor / baseFactor : currentFactor
        if let match = options.first(where: { abs($0.factor - currentFactor) < 0.02 }) {
            return match.label
        }
        return relative < 1
            ? String(format: "%.1f", relative)
            : (relative < 10 ? String(format: "%.1f", relative) : String(format: "%.0f", relative))
    }

    private func isActive(_ option: CameraZoomOption) -> Bool {
        abs(option.factor - currentFactor) < 0.02
    }

    private func dot(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(label)×")
                .font(.system(size: isActive ? 13 : 12, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? .yellow : .white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(
                    Circle().stroke(.white.opacity(isActive ? 0.9 : 0.25), lineWidth: isActive ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}
