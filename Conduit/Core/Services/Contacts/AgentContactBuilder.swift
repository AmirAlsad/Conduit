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
    /// Neutral system label ("other") for the synthetic email — the `@conduit.invalid`
    /// value already identifies it, so no need for a prominent custom label.
    static let emailLabel = CNLabelOther

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
