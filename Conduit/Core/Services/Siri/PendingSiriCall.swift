//
//  PendingSiriCall.swift
//  Conduit
//
//  A Siri dial request parked until the scene is .active. Carries its request
//  time because a request can be set and never consumed (e.g. Siri invoked on
//  the locked phone, app never foregrounded) — without an expiry, the next
//  unrelated activation would resurrect it and place a phantom call.
//

import Foundation

struct PendingSiriCall: Equatable {
    static let maxAge: TimeInterval = 30

    let agentID: UUID
    let requestedAt: Date

    init(agentID: UUID, requestedAt: Date = .now) {
        self.agentID = agentID
        self.requestedAt = requestedAt
    }

    var isExpired: Bool {
        Date.now.timeIntervalSince(requestedAt) > Self.maxAge
    }
}
