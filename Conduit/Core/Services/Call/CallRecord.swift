//
//  CallRecord.swift
//  Conduit
//
//  A finished call (or a ring that never reached the user), reported to the host
//  through `CallEngineDelegate.callEngine(_:didFinish:)`. The host decides what to
//  persist or notify.
//

import Foundation

struct CallRecord: Equatable, Sendable {
    let targetID: UUID
    let direction: CallDirection
    let startedAt: Date
    /// Connected duration in seconds; 0 for a call that never connected.
    let duration: TimeInterval
    let outcome: CallOutcome
    let failureReason: CallFailureReason?
    /// Non-nil only when the ring never reached the user.
    let missedReason: MissedCallReason?

    init(
        targetID: UUID,
        direction: CallDirection,
        startedAt: Date,
        duration: TimeInterval,
        outcome: CallOutcome,
        failureReason: CallFailureReason? = nil,
        missedReason: MissedCallReason? = nil
    ) {
        self.targetID = targetID
        self.direction = direction
        self.startedAt = startedAt
        self.duration = duration
        self.outcome = outcome
        self.failureReason = failureReason
        self.missedReason = missedReason
    }
}

enum MissedCallReason: Sendable {
    /// Another call was live, so the ring was reported and ended at once.
    case busy
    /// Focus / Do Not Disturb suppressed the ring.
    case filteredByFocus
}
