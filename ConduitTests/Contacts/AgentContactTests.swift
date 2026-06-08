//
//  AgentContactTests.swift
//  ConduitTests
//
//  The pure mapping from an agent's identity snapshot to the pre-filled system
//  contact. The contact is saved by the user through `CNContactViewController`
//  (no store access), so this mapping is the only logic worth asserting.
//

import Contacts
import Testing
@testable import Conduit

struct AgentContactTests {
    private let info = AgentMirrorInfo(
        id: UUID(),
        displayName: "Echo Bot",
        avatarData: Data([0xDE, 0xAD]),
        syntheticEmail: "echo-bot-ab12cd34.agent.conduit.invalid"
    )

    @Test func mapsNameAvatarAndEmail() {
        let contact = AgentContactBuilder.makeContact(from: info)

        #expect(contact.givenName == "Echo Bot")
        #expect(contact.imageData == Data([0xDE, 0xAD]))
        #expect(contact.emailAddresses.count == 1)
        let email = contact.emailAddresses.first
        #expect(email?.value as String? == info.syntheticEmail)
        #expect(email?.label == AgentContactBuilder.emailLabel)
    }

    @Test func omitsImageWhenNoAvatar() {
        let bare = AgentMirrorInfo(
            id: UUID(),
            displayName: "No Photo",
            avatarData: nil,
            syntheticEmail: "no-photo-00000000.agent.conduit.invalid"
        )
        let contact = AgentContactBuilder.makeContact(from: bare)
        #expect(contact.imageData == nil)
        #expect(contact.givenName == "No Photo")
    }
}
