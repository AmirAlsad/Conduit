//
//  CallFailureReason+Display.swift
//  Conduit
//
//  User-facing copy for failure reasons, shared by the in-call status line, the
//  failed-call hint, and the Recents / Agent Detail log rows. Pure, so the copy
//  is verified by unit tests at simulator speed.
//

import ConduitCallEngine
import Foundation

extension CallFailureReason {
    /// The in-call status line ("Authentication failed").
    var displayLabel: String {
        switch self {
        case .badToken: "Authentication failed"
        case .agentUnreachable: "Agent didn't join"
        case .lostConnection: "Connection lost"
        case .transportError: "Couldn't connect"
        case .unknown: "Call failed"
        @unknown default: "Call failed"
        }
    }

    /// A lowercase qualifier for log rows ("Failed — authentication");
    /// nil where it would add nothing over plain "Failed".
    var shortLabel: String? {
        switch self {
        case .badToken: "authentication"
        case .agentUnreachable: "agent didn't join"
        case .lostConnection: "connection lost"
        case .transportError: "couldn't connect"
        case .unknown: nil
        @unknown default: nil
        }
    }

    /// One actionable line under the failed-call status.
    var hint: String {
        switch self {
        case .badToken: "Check the API key in this agent's settings."
        case .agentUnreachable: "Conduit reached the call, but your agent never joined it. Check that your server starts the agent for each call."
        case .lostConnection: "The network dropped — try calling again."
        case .transportError: "Check the transport setting and your server's credentials."
        case .unknown: "Try again."
        @unknown default: "Try again."
        }
    }
}
