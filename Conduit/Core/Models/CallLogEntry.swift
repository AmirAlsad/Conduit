//
//  CallLogEntry.swift
//  Conduit
//
//  One row in the call log, persisted with SwiftData. Deleting an `Agent`
//  cascades its entries; deleting a single entry nullifies its `agent` and
//  removes only the row (history removed, agent kept).
//

import Foundation
import SwiftData

@Model
final class CallLogEntry {
    @Attribute(.unique) var id: UUID
    var agent: Agent?
    var directionRaw: String
    var startedAt: Date
    /// Connected duration in seconds; 0 for a call that never connected.
    var duration: TimeInterval
    var outcomeRaw: String
    var transportKindRaw: String
    /// Why a `.failed` call failed; nil for non-failed outcomes and rows that
    /// predate this field (optional ⇒ lightweight migration).
    var failureReasonRaw: String?

    init(
        id: UUID = UUID(),
        agent: Agent? = nil,
        direction: CallDirection = .outgoing,
        startedAt: Date = .now,
        duration: TimeInterval = 0,
        outcome: CallOutcome,
        transportKind: TransportKind,
        failureReason: CallFailureReason? = nil
    ) {
        self.id = id
        self.agent = agent
        self.directionRaw = direction.rawValue
        self.startedAt = startedAt
        self.duration = duration
        self.outcomeRaw = outcome.rawValue
        self.transportKindRaw = transportKind.rawValue
        self.failureReasonRaw = failureReason?.rawValue
    }

    var direction: CallDirection {
        CallDirection(rawValue: directionRaw) ?? .outgoing
    }

    var outcome: CallOutcome {
        CallOutcome(rawValue: outcomeRaw) ?? .failed
    }

    var transportKind: TransportKind {
        TransportKind(rawValue: transportKindRaw) ?? .daily
    }

    var failureReason: CallFailureReason? {
        failureReasonRaw.flatMap(CallFailureReason.init(rawValue:))
    }
}
