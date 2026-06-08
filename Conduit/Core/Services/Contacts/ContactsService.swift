//
//  ContactsService.swift
//  Conduit
//
//  Real `ContactsMirroring` over `CNContactStore`. The optional mirror writes a
//  system contact whose email field holds the agent's synthetic `.invalid`
//  handle, so the OS matches an outgoing call to it and the native call UI shows
//  the agent's name + photo instead of the raw handle.
//
//  Lifecycle (owned with the caller, WS-5): permission is requested only when the
//  per-agent toggle is flipped on; `upsertMirror` runs on add/edit; `removeMirror`
//  on delete or toggle-off. Known caveat: an app-created contact can linger in the
//  address book after the app is uninstalled (iOS gives no uninstall hook).
//
//  `removeMirror` receives only the agent id, so the contact is located by the
//  stable `id8` suffix of the synthetic email (the email is minted once at agent
//  creation and never changes, even on rename).
//
//  Device/manual-verified: the `CNContactStore` round-trip needs Contacts
//  permission and writes the address book, so it can't run in the unit suite —
//  the pure mapping below (`configure`, `emailSuffix`) is what's unit-tested.
//

import Contacts
import Foundation

final class ContactsService: ContactsMirroring, @unchecked Sendable {
    private let store: CNContactStore

    /// Custom email label tagging Conduit-created entries in the address book.
    static let emailLabel = "Conduit"

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    func authorizationStatus() -> ContactsAuthStatus {
        ContactsAuthStatus(CNContactStore.authorizationStatus(for: .contacts))
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error { Log.error(.contacts, "Contacts access request failed: \(error)") }
                continuation.resume(returning: granted)
            }
        }
    }

    func upsertMirror(for info: AgentMirrorInfo) async throws {
        let keys = [
            CNContactGivenNameKey, CNContactEmailAddressesKey, CNContactImageDataKey,
        ] as [CNKeyDescriptor]

        let request = CNSaveRequest()
        if let existing = try firstContact(keys: keys, where: {
            ContactsService.emails($0).contains { $0.caseInsensitiveCompare(info.syntheticEmail) == .orderedSame }
        }) {
            // mutableCopy() is documented to return a CNMutableContact for CNContact.
            let mutable = existing.mutableCopy() as! CNMutableContact
            ContactsService.configure(mutable, from: info)
            request.update(mutable)
        } else {
            let mutable = CNMutableContact()
            ContactsService.configure(mutable, from: info)
            request.add(mutable, toContainerWithIdentifier: nil)
        }
        try store.execute(request)
    }

    func removeMirror(agentID: UUID) async throws {
        let keys = [CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let suffix = ContactsService.emailSuffix(forAgentID: agentID)
        guard let contact = try firstContact(keys: keys, where: {
            ContactsService.emails($0).contains { $0.lowercased().hasSuffix(suffix) }
        }) else { return }

        let request = CNSaveRequest()
        request.delete(contact.mutableCopy() as! CNMutableContact)
        try store.execute(request)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Configure a mutable contact to mirror an agent. Replacing the whole email
    /// set is safe: these are app-created contacts, matched on our synthetic email.
    static func configure(_ contact: CNMutableContact, from info: AgentMirrorInfo) {
        contact.givenName = info.displayName
        contact.imageData = info.avatarData
        contact.emailAddresses = [
            CNLabeledValue(label: emailLabel, value: info.syntheticEmail as NSString)
        ]
    }

    /// The stable tail of an agent's synthetic email — `-<id8>.agent.conduit.invalid`.
    /// Independent of the name slug, so it locates the contact after a rename.
    static func emailSuffix(forAgentID id: UUID) -> String {
        let shortID = id.uuidString.prefix(8).lowercased()
        return "-\(shortID).agent.conduit.invalid"
    }

    // MARK: - Lookup

    private func firstContact(
        keys: [CNKeyDescriptor],
        where matches: @escaping (CNContact) -> Bool
    ) throws -> CNContact? {
        let request = CNContactFetchRequest(keysToFetch: keys)
        var found: CNContact?
        try store.enumerateContacts(with: request) { contact, stop in
            if matches(contact) {
                found = contact
                stop.pointee = true
            }
        }
        return found
    }

    private static func emails(_ contact: CNContact) -> [String] {
        contact.emailAddresses.map { $0.value as String }
    }
}

private extension ContactsAuthStatus {
    init(_ status: CNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .limited: self = .limited
        @unknown default: self = .denied
        }
    }
}
