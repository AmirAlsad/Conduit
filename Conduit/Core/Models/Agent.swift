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
    /// The agent's identity color, stored as an `AgentColor` token (never RGBA).
    /// Optional with no default so the migration is additive and CloudKit-safe;
    /// `nil` only on agents that predate the field and resolves to the name-derived
    /// color (see `paletteColor`). New agents always get a concrete token at init.
    var colorTokenRaw: String?
    /// Stable synthetic `.invalid` email used as the call's email-type handle.
    var syntheticEmail: String
    var transportKindRaw: String
    /// Direct-mode room URL. `nil` for a pairing-only agent (see `pairingEndpoint`).
    var connectionURL: URL?
    /// Pairing flow: a URL the app POSTs for a fresh room+token per call. The
    /// endpoint identifies the agent (one endpoint per agent).
    var pairingEndpoint: URL?
    /// Inbound calls: a URL the app POSTs its VoIP push token to (bearer = the
    /// agent's API key), so this agent's own server can ring the user. `nil` means
    /// the agent can't call in. See `VoIPPushService` and `docs/INBOUND_CALLS.md`.
    var inboundRegistrationURL: URL?
    /// `CNContact.identifier` of the system contact, once the user adds the agent
    /// via the system Add-Contact sheet. `nil` means not added.
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
        colorToken: AgentColor? = nil,
        transportKind: TransportKind,
        connectionURL: URL? = nil,
        pairingEndpoint: URL? = nil,
        inboundRegistrationURL: URL? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.avatarData = avatarData
        // Stamp a concrete color at creation (frozen on rename); fall back to the
        // name-derived slot so every creation path — deep links included — gets one.
        self.colorTokenRaw = (colorToken ?? .derived(forName: name)).rawValue
        self.syntheticEmail = Agent.makeSyntheticEmail(name: name)
        self.transportKindRaw = transportKind.rawValue
        self.connectionURL = connectionURL
        self.pairingEndpoint = pairingEndpoint
        self.inboundRegistrationURL = inboundRegistrationURL
        self.contactIdentifier = nil
        self.keychainTokenRef = KeychainTokenRef(agentID: id).account
        self.createdAt = createdAt
        self.callLog = []
    }

    var transportKind: TransportKind {
        TransportKind(rawValue: transportKindRaw) ?? .daily
    }

    /// The agent's identity color. Falls back to the name-derived slot for legacy
    /// agents whose token predates the field (`nil`).
    var paletteColor: AgentColor {
        colorTokenRaw.flatMap(AgentColor.init(rawValue:)) ?? .derived(forName: name)
    }
}
