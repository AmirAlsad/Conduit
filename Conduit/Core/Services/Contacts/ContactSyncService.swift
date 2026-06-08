//
//  ContactSyncService.swift
//  Conduit
//
//  Real `ContactSyncing` over `CNContactStore`. Updates the contact identified by
//  the agent's stored `contactIdentifier`, leaving its email (the call-handle link)
//  and any other fields the user added untouched — only name + photo follow the
//  agent. Requests Contacts access lazily; `.denied`/`.restricted` returns false
//  without re-prompting.
//

import Contacts
import Foundation

final class ContactSyncService: ContactSyncing, @unchecked Sendable {
    private let store: CNContactStore

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    func sync(_ info: AgentMirrorInfo, contactIdentifier: String) async -> Bool {
        guard await ensureAccess() else { return false }

        let keys = [
            CNContactGivenNameKey, CNContactImageDataKey, CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
        do {
            let existing = try store.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keys)
            // mutableCopy() is documented to return a CNMutableContact for CNContact.
            let mutable = existing.mutableCopy() as! CNMutableContact
            mutable.givenName = info.displayName
            mutable.imageData = info.avatarData

            let request = CNSaveRequest()
            request.update(mutable)
            try store.execute(request)
            return true
        } catch {
            Log.error(.contacts, "Contact sync failed: \(error)")
            return false
        }
    }

    private func ensureAccess() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                store.requestAccess(for: .contacts) { granted, error in
                    if let error { Log.error(.contacts, "Contacts access request failed: \(error)") }
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
}
