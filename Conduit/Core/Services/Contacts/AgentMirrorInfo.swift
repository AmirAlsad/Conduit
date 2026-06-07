//
//  AgentMirrorInfo.swift
//  Conduit
//
//  A flat snapshot of the agent's display identity handed to the contacts mirror,
//  so the service never imports SwiftData. The synthetic email is written into the
//  contact's email field so the system call UI matches the contact (name + photo).
//

import Foundation

struct AgentMirrorInfo: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let avatarData: Data?
    let syntheticEmail: String
}
