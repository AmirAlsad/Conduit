//
//  ReturnToCallToolbar.swift
//  Conduit
//
//  A leading nav-bar affordance to return to a minimized call. The Dynamic Island
//  only re-foregrounds the call from *outside* the app, so it can't help while the
//  app is open; this fills that gap. Applied only to the root tab screens (whose
//  leading slot is free) — pushed screens and sheets own that slot themselves, so
//  it never collides with a back/cancel button. Tinted in the agent's color.
//

import SwiftUI

struct ReturnToCallToolbarModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content.toolbar {
            if environment.callSession.state.isActive, environment.isCallScreenMinimized {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        environment.isCallScreenMinimized = false
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "phone.fill")
                            Text(environment.callSession.activeAgent?.name ?? "Call")
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            environment.callSession.activeAgent?.paletteColor.color ?? .green,
                            in: .capsule
                        )
                    }
                    .accessibilityLabel("Return to call")
                    .accessibilityIdentifier(AccessibilityID.Root.returnToCall)
                }
            }
        }
    }
}

extension View {
    /// Shows a "return to call" button in the leading nav-bar slot while a call is
    /// minimized. Apply only to screens with a free leading slot (the root tabs).
    func returnToCallToolbar() -> some View {
        modifier(ReturnToCallToolbarModifier())
    }
}
