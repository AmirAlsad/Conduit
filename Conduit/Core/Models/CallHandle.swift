//
//  CallHandle.swift
//  Conduit
//
//  The handle a call is placed against. Agents have no real phone/email, so this
//  carries the agent's stable synthetic `.invalid` email. The real CallKit
//  provider maps it to a `CXHandle` of type `.emailAddress` — email type is
//  deliberate, so Siri/CallKit read the agent's display name rather than the raw
//  alphanumeric ID. Kept CallKit-agnostic so the seam stays testable.
//

import Foundation

struct CallHandle: Equatable, Sendable {
    let value: String
}
