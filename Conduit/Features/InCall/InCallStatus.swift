//
//  InCallStatus.swift
//  Conduit
//
//  Pure CallState → status-line text mapping for the in-call surface, plus when
//  the call can be held. Kept free of SwiftUI so the copy is verified by unit
//  tests at simulator speed. `.connected` has no string here — the view renders a
//  live timer in its place.
//

import ConduitCallEngine
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
        reason.displayLabel
    }

    static let onHold = "On Hold"

    /// The status line of a call that is up but paused, shown in place of the
    /// state's own: on hold (from the hold control, the system call screen, or iOS
    /// for a phone call), else interrupted (Siri, navigation). nil when neither, and
    /// once the call has ended.
    static func pausedText(for state: CallState, isOnHold: Bool, isInterrupted: Bool) -> String? {
        guard !state.isTerminal else { return nil }
        if isOnHold { return onHold }
        if isInterrupted { return "Paused" }
        return nil
    }

    /// Whether the hold control applies: the engine holds a call only while it is
    /// connecting, connected or reconnecting.
    static func canHold(_ state: CallState) -> Bool {
        switch state {
        case .connecting, .connected, .reconnecting: true
        case .idle, .incomingRinging, .dialing, .ended, .failed: false
        }
    }
}
