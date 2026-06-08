//
//  SpeakingGlowModifier.swift
//  Conduit
//
//  A soft glow behind the agent avatar on the in-call screen that breathes with
//  the agent's voice — a passenger's at-a-glance "it's talking" cue. Driven by the
//  remote audio level (0...1) and whether the bot is currently speaking. Honors
//  Reduce Motion by dropping the animation.
//

import SwiftUI

struct SpeakingGlowModifier: ViewModifier {
    var isActive: Bool
    var level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                Circle()
                    .fill(.tint)
                    .opacity(isActive ? 0.4 : 0.12)
                    .scaleEffect(scale)
                    .blur(radius: 28)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: scale)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: isActive)
            }
            .accessibilityHidden(true)
    }

    private var scale: CGFloat {
        guard isActive else { return 1 }
        let clamped = CGFloat(max(0, min(1, level)))
        return 1 + clamped * 0.45
    }
}

extension View {
    /// A voice-reactive glow behind the content (the agent avatar).
    func speakingGlow(isActive: Bool, level: Float) -> some View {
        modifier(SpeakingGlowModifier(isActive: isActive, level: level))
    }
}
