//
//  CallState.swift
//  Conduit
//
//  The call's lifecycle, owned by the call coordinator. Pure and Equatable so
//  the state machine — the most-tested unit in the app — verifies against fakes
//  at simulator speed.
//
//  idle → dialing → connecting → connected → (reconnecting ⇄ connected) → ended
//                                          ↘ failed
//

import Foundation

enum CallState: Equatable, Sendable {
    /// No call in progress.
    case idle
    /// User asked to call; the call is being reported to CallKit.
    case dialing
    /// CallKit has the call; the transport is connecting (token loaded, joining).
    case connecting
    /// Transport ready AND bot ready; the running timer starts at `since`.
    case connected(since: Date)
    /// Media dropped while CallKit still believes the call is up; backing off.
    case reconnecting(attempt: Int)
    /// The call finished normally (or was canceled/ended).
    case ended(CallOutcome)
    /// The call could not be established or could not recover.
    case failed(CallFailureReason)
}

extension CallState {
    /// Whether a call surface should be shown (anything other than idle).
    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }

    /// Whether the call has reached a terminal state.
    var isTerminal: Bool {
        switch self {
        case .ended, .failed: return true
        default: return false
        }
    }
}
