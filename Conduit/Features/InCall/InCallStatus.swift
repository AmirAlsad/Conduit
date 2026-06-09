//
//  InCallStatus.swift
//  Conduit
//
//  Pure CallState → status-line text mapping for the in-call surface. Kept free of
//  SwiftUI so the copy is verified by unit tests at simulator speed. `.connected`
//  has no string here — the view renders a live timer in its place.
//

import Foundation

enum InCallStatus {
    /// The status line shown under the agent name. `nil` for `.connected`, where
    /// the view shows a live call timer instead, and for `.idle` (no call surface).
    static func text(for state: CallState) -> String? {
        switch state {
        case .idle:
            return nil
        case .incomingRinging:
            return "Incoming…"
        case .dialing:
            return "Calling…"
        case .connecting:
            return "Connecting…"
        case .connected:
            return nil
        case .reconnecting:
            return "Reconnecting…"
        case .ended:
            return "Call Ended"
        case .failed(let reason):
            return text(for: reason)
        }
    }

    static func text(for reason: CallFailureReason) -> String {
        switch reason {
        case .badToken:
            return "Authentication failed"
        case .agentUnreachable:
            return "Agent unavailable"
        case .lostConnection:
            return "Connection lost"
        case .transportError:
            return "Couldn't connect"
        case .unknown:
            return "Call failed"
        }
    }
}
