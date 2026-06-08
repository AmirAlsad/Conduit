//
//  ContactsServiceIntegrationTests.swift
//  ConduitTests
//
//  Exercises the REAL `ContactsService` against the live `CNContactStore`. Unlike
//  CallKit/WebRTC, the address book is fully functional in the simulator, so this
//  round-trip runs there once Contacts permission is granted:
//
//      xcrun simctl privacy booted grant contacts com.amiralsad.Conduit
//
//  Without permission the suite is skipped (keeps CI green), so it never blocks on
//  the system prompt. Serialized + unique-per-run emails so it never races or
//  collides in the shared address book; it removes whatever it creates.
//

import Contacts
import Foundation
import Testing
import UIKit
@testable import Conduit

@Suite(.serialized)
struct ContactsServiceIntegrationTests {
    static var contactsAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    @Test(.enabled(if: ContactsServiceIntegrationTests.contactsAuthorized))
    func mirrorRoundTripsThroughTheAddressBook() async throws {
        let service = ContactsService()
        let id = UUID()
        let email = Agent.makeSyntheticEmail(name: "Integration Agent", id: id)
        // A real image: CNContactStore validates imageData on save.
        let avatar = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        // Ensure a clean slate even if a prior run failed before cleanup.
        try await service.removeMirror(agentID: id)

        do {
            // Create.
            try await service.upsertMirror(for: AgentMirrorInfo(
                id: id, displayName: "Integration Agent", avatarData: avatar, syntheticEmail: email
            ))
            let created = try #require(fetchContacts(withEmail: email).first)
            #expect(fetchContacts(withEmail: email).count == 1)
            #expect(created.givenName == "Integration Agent")
            #expect(created.imageData != nil) // store may re-encode; presence is what matters

            // Update (rename, same id → same email): mutate in place, no duplicate.
            try await service.upsertMirror(for: AgentMirrorInfo(
                id: id, displayName: "Renamed Agent", avatarData: nil, syntheticEmail: email
            ))
            let updated = try #require(fetchContacts(withEmail: email).first)
            #expect(fetchContacts(withEmail: email).count == 1)
            #expect(updated.givenName == "Renamed Agent")

            // Remove by agent id alone (located via the stable id8 suffix).
            try await service.removeMirror(agentID: id)
            #expect(fetchContacts(withEmail: email).isEmpty)
        } catch {
            try? await service.removeMirror(agentID: id)
            throw error
        }
    }

    private func fetchContacts(withEmail email: String) -> [CNContact] {
        let store = CNContactStore()
        let keys = [
            CNContactGivenNameKey, CNContactEmailAddressesKey, CNContactImageDataKey,
        ] as [CNKeyDescriptor]
        var matches: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            let hit = contact.emailAddresses.contains {
                ($0.value as String).caseInsensitiveCompare(email) == .orderedSame
            }
            if hit { matches.append(contact) }
        }
        return matches
    }
}
