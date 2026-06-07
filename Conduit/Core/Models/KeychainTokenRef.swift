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

    init(agentID: UUID) {
        self.account = "agent.token.\(agentID.uuidString)"
    }
}
