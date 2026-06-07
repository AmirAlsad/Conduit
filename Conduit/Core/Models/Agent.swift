//
//  Agent.swift
//  Conduit
//
//  An agent the user calls — the in-app source of truth, persisted with
//  SwiftData. The connection token is NOT stored here; only `keychainTokenRef`
//  points to it in the Keychain. See `Agent+Handle.swift` for the synthetic
//  email handle.
//

import Foundation
import SwiftData

@Model
final class Agent {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Shown as the row's second line (like a contact label). `description` is a
    /// reserved name on reference types, so this is `detail`.
    var detail: String
    @Attribute(.externalStorage) var avatarData: Data?
    /// Stable synthetic `.invalid` email used as the call's email-type handle.
    var syntheticEmail: String
    var transportKindRaw: String
    var connectionURL: URL
    /// Later QR/pairing flow: a URL the app calls for a fresh room+token per call.
    var pairingEndpoint: URL?
    var mirrorsToContacts: Bool
    /// `CNContact.identifier` of the mirrored system contact, once created.
    var contactIdentifier: String?
    /// Keychain account string for this agent's token (never the token itself).
    var keychainTokenRef: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \CallLogEntry.agent)
    var callLog: [CallLogEntry]

    init(
        id: UUID = UUID(),
        name: String,
        detail: String = "",
        avatarData: Data? = nil,
        transportKind: TransportKind,
        connectionURL: URL,
        pairingEndpoint: URL? = nil,
        mirrorsToContacts: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.avatarData = avatarData
        self.syntheticEmail = Agent.makeSyntheticEmail(name: name, id: id)
        self.transportKindRaw = transportKind.rawValue
        self.connectionURL = connectionURL
        self.pairingEndpoint = pairingEndpoint
        self.mirrorsToContacts = mirrorsToContacts
        self.contactIdentifier = nil
        self.keychainTokenRef = KeychainTokenRef(agentID: id).account
        self.createdAt = createdAt
        self.callLog = []
    }

    var transportKind: TransportKind {
        TransportKind(rawValue: transportKindRaw) ?? .daily
    }
}
