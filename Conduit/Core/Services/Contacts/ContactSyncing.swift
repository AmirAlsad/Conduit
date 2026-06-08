//
//  ContactSyncing.swift
//  Conduit
//
//  Narrow seam for keeping a *already-linked* system contact up to date with its
//  agent (name + photo) when the agent is edited. Distinct from adding a contact:
//  adding is permission-free via the system sheet (`NewContactView`), but updating
//  an existing contact in place must go through `CNContactStore`, which needs the
//  one-time Contacts permission. Requested lazily — only the first time a linked
//  agent is saved — so anyone who never links (or links but never edits) is never
//  prompted.
//

import Foundation

protocol ContactSyncing: Sendable {
    /// Update the linked contact's name + photo from `info`. Requests Contacts
    /// access on first use; returns `false` if access is denied or the contact is
    /// gone (caller leaves the stored identifier as-is — a future grant retries).
    func sync(_ info: AgentMirrorInfo, contactIdentifier: String) async -> Bool
}
