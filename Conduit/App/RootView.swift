//
//  RootView.swift
//  Conduit
//
//  Placeholder root view. The real UI — a three-tab, Phone-style app
//  (Recents / Contacts / Settings) — is feature work; see
//  voice-agent-callkit-plan.md.
//

import SwiftUI

struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.connection.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Conduit")
                .font(.largeTitle.bold())
            Text("Call your agent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityIdentifier(AccessibilityID.Root.screen)
    }
}

#Preview {
    RootView()
}
