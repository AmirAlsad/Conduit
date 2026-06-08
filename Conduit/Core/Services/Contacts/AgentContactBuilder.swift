//
//  AgentContactBuilder.swift
//  Conduit
//
//  Builds the pre-filled system contact for an agent. The contact is handed to
//  `CNContactViewController(forNewContact:)` (see `NewContactView`), so the user
//  saves it through system UI — Conduit never holds Contacts permission and never
//  writes the address book itself.
//
//  The synthetic `.invalid` email is the link: it matches the call's email-type
//  CXHandle, so once the contact exists iOS shows the agent's name + photo on the
//  call screen, lock screen, and CarPlay in place of the raw handle.
//

import Contacts

enum AgentContactBuilder {
    /// Custom email label tagging Conduit-created entries in the address book.
    static let emailLabel = "Conduit"

    static func makeContact(from info: AgentMirrorInfo) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = info.displayName
        contact.imageData = info.avatarData
        contact.emailAddresses = [
            CNLabeledValue(label: emailLabel, value: info.syntheticEmail as NSString)
        ]
        return contact
    }
}
