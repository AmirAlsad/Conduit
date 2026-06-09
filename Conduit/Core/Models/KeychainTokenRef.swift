//
//  KeychainTokenRef.swift
//  Conduit
//
//  A typed reference to where an agent's connection token lives in the Keychain.
//  An `Agent` persists only this ref (a deterministic account string), never the
//  token itself — tokens never touch SwiftData, a contact, a log, or git.
//

import Foundation

struct KeychainTokenRef: Equatable, Sendable {
    let account: String

    init(account: String) {
        self.account = account
    }

    /// The pairing API key (bearer) — also the agent's primary `keychainTokenRef`.
    init(agentID: UUID) {
        self.account = "agent.token.\(agentID.uuidString)"
    }

    /// The direct-room token, a secret distinct from the pairing API key so an agent
    /// can carry both independently.
    init(directTokenForAgentID agentID: UUID) {
        self.account = "agent.directToken.\(agentID.uuidString)"
    }
}
