//
//  AgentMirrorInfo.swift
//  Conduit
//
//  A flat snapshot of the agent's display identity used to build the pre-filled
//  system contact (`AgentContactBuilder`), so the contact layer never imports
//  SwiftData. The synthetic email is written into the contact's email field so the
//  system call UI matches the contact (name + photo).
//

import Foundation

struct AgentMirrorInfo: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let avatarData: Data?
    let syntheticEmail: String
}
