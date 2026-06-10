//
//  AgentEntity.swift
//  Conduit
//
//  The App Intents face of an Agent: what Siri's vocabulary, the Shortcuts app,
//  and the "Call <agent> on Conduit" phrase parameter see. Identity is the
//  agent's UUID; only id + name cross the intent boundary.
//
//  The type name and parameter shape are FROZEN: App Shortcut identity keys on
//  them, and the planned iOS 27 `.phone.startCall` schema adoption must upgrade
//  this same type in place without breaking shipped shortcuts.
//

import AppIntents
import Foundation

struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static let defaultQuery = AgentEntityQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(agent: Agent) {
        self.init(id: agent.id, name: agent.name)
    }
}
