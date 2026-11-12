//
//  MissedCallReason+Display.swift
//  Conduit
//
//  User-facing copy for a missed incoming ring, shared by the Recents / Agent
//  Detail log rows and the missed-call notification. A ring that rang and went
//  unanswered reads as a plain missed call, as in the Phone app; one the user
//  never heard says why.
//

import ConduitCallEngine
import Foundation

extension MissedCallReason {
    /// A qualifier for log rows ("Missed — Focus"); nil for a ring that rang.
    var shortLabel: String? {
        switch self {
        case .busy: "on another call"
        case .filteredByFocus: "Focus"
        case .ringTimedOut, .canceledByCaller: nil
        }
    }

    func notificationBody(agentName: String) -> String {
        switch self {
        case .busy: "\(agentName) tried to call you during another call."
        case .filteredByFocus: "\(agentName) tried to call you while Focus was on."
        case .ringTimedOut, .canceledByCaller: "\(agentName) tried to call you."
        }
    }
}
