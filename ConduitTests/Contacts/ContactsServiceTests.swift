//
//  ContactsServiceTests.swift
//  ConduitTests
//
//  The pure mapping in `ContactsService` — building a mirror contact and the
//  stable email suffix used to locate it for removal. The `CNContactStore`
//  round-trip needs Contacts permission + writes the address book, so it's
//  device/manual-verified, not exercised here.
//

import Contacts
import Foundation
import Testing
@testable import Conduit

struct ContactsServiceTests {
    @Test func configureSetsNamePhotoAndSyntheticEmail() throws {
        let avatar = Data([0x01, 0x02, 0x03])
        let info = AgentMirrorInfo(
            id: UUID(),
            displayName: "Jarvis",
            avatarData: avatar,
            syntheticEmail: "jarvis-1a2b3c4d.agent.conduit.invalid"
        )

        let contact = CNMutableContact()
        ContactsService.configure(contact, from: info)

        #expect(contact.givenName == "Jarvis")
        #expect(contact.imageData == avatar)
        let email = try #require(contact.emailAddresses.first)
        #expect(contact.emailAddresses.count == 1)
        #expect(email.value as String == info.syntheticEmail)
        #expect(email.label == ContactsService.emailLabel)
    }

    @Test func configureReplacesPriorEmailsAndClearsStalePhoto() throws {
        let contact = CNMutableContact()
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "stale@example.com" as NSString)]
        contact.imageData = Data([0xFF])
        let info = AgentMirrorInfo(
            id: UUID(),
            displayName: "Echo",
            avatarData: nil,
            syntheticEmail: "echo-deadbeef.agent.conduit.invalid"
        )

        ContactsService.configure(contact, from: info)

        let email = try #require(contact.emailAddresses.first)
        #expect(contact.emailAddresses.count == 1)
        #expect(email.value as String == info.syntheticEmail)
        #expect(contact.imageData == nil)
    }

    @Test func emailSuffixIsStableLowercasedID8() throws {
        let id = try #require(UUID(uuidString: "1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D"))
        #expect(ContactsService.emailSuffix(forAgentID: id) == "-1a2b3c4d.agent.conduit.invalid")
    }

    @Test func suffixMatchesMintedEmailRegardlessOfName() {
        let id = UUID()
        // The invariant that makes removeMirror(agentID:) work: the suffix used to
        // locate the contact must match the email upsert minted, for any name.
        let email = Agent.makeSyntheticEmail(name: "Some Renamed Agent!!", id: id)
        #expect(email.lowercased().hasSuffix(ContactsService.emailSuffix(forAgentID: id)))
    }
}
