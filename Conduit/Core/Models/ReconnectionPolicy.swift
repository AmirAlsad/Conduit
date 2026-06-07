//
//  ReconnectionPolicy.swift
//  Conduit
//
//  The exponential-backoff policy for recovering a dropped media connection while
//  CallKit still believes the call is up. Pure and deterministic so it unit-tests
//  in isolation; the coordinator runs the loop and injects the actual sleep.
//

import Foundation

struct ReconnectionPolicy: Equatable, Sendable {
    /// Maximum number of reconnection attempts before the call is declared lost.
    let maxAttempts: Int
    let baseDelaySeconds: Double
    let maxDelaySeconds: Double

    static let `default` = ReconnectionPolicy(
        maxAttempts: 6,
        baseDelaySeconds: 1,
        maxDelaySeconds: 30
    )

    /// Whether an attempt numbered `attempt` (1-based) is still within budget.
    func canAttempt(_ attempt: Int) -> Bool {
        attempt <= maxAttempts
    }

    /// Backoff before the given 1-based attempt: `base * 2^(n-1)`, capped.
    func delay(forAttempt attempt: Int) -> Duration {
        guard attempt >= 1 else { return .zero }
        let raw = baseDelaySeconds * pow(2, Double(attempt - 1))
        return .seconds(min(raw, maxDelaySeconds))
    }
}
