//
//  ContactRow.swift
//  Conduit
//
//  One agent in the Contacts list: avatar, name, a secondary label, and a call
//  button. The call button uses `.borderless` so tapping it doesn't also fire
//  the enclosing NavigationLink.
//

import SwiftUI

struct ContactRow: View {
    let agent: Agent
    let callButtonID: String
    let onCall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatarView(name: agent.name, imageData: agent.avatarData, color: agent.paletteColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.headline)
                Text(secondaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCall) {
                Image(systemName: "phone.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.green)
            .accessibilityIdentifier(callButtonID)
            .accessibilityLabel("Call \(agent.name)")
        }
        .padding(.vertical, 4)
    }

    private var secondaryLine: String {
        agent.detail.isEmpty ? agent.transportKind.displayName : agent.detail
    }
}

#Preview {
    List {
        ContactRow(
            agent: Agent(
                name: "Jarvis",
                detail: "Personal assistant",
                transportKind: .daily,
                connectionURL: URL(string: "https://example.daily.co/room")!
            ),
            callButtonID: AccessibilityID.Contacts.callButton(0),
            onCall: {}
        )
        ContactRow(
            agent: Agent(
                name: "Echo Bot",
                transportKind: .livekit,
                connectionURL: URL(string: "wss://example.livekit.cloud")!
            ),
            callButtonID: AccessibilityID.Contacts.callButton(1),
            onCall: {}
        )
    }
}
