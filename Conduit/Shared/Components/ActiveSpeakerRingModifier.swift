//
//  ActiveSpeakerRingModifier.swift
//  Conduit
//
//  A subtle ring around the agent avatar that appears while the agent is speaking
//  — the group-FaceTime "active tile" cue, kept in human-call language. It replaced
//  an amplitude glow that read as "AI." Binary on speaking; not amplitude-driven.
//

import SwiftUI

struct ActiveSpeakerRingModifier: ViewModifier {
    var isActive: Bool
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                Circle()
                    .strokeBorder(color, lineWidth: 4)
                    .padding(-8)
                    .opacity(isActive ? 0.9 : 0)
                    .scaleEffect(isActive ? 1 : 0.94)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: isActive)
            }
            .accessibilityHidden(true)
    }
}

extension View {
    /// A speaking-indicator ring around the agent avatar.
    func activeSpeakerRing(isActive: Bool, color: Color) -> some View {
        modifier(ActiveSpeakerRingModifier(isActive: isActive, color: color))
    }
}
