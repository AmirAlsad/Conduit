//
//  CallOutcome+Display.swift
//  Conduit
//
//  UI presentation for a call outcome (icon, tint, label), shared by the Recents
//  list and the per-agent call history. Lives in Shared (the UI layer) so Core
//  models stay free of SwiftUI.
//

import ConduitCallEngine
import SwiftUI

extension CallOutcome {
    /// The arrow points the way the call went: up-right for a call the user
    /// placed, down-left for one from the agent.
    func iconName(for direction: CallDirection) -> String {
        switch self {
        case .failed, .declined: "phone.down.fill"
        case .completed, .noAnswer, .canceled:
            direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right"
        }
    }

    /// Recents renders `failed` red; everything else reads neutral.
    var tint: Color {
        switch self {
        case .completed: .green
        case .failed: .red
        case .declined, .noAnswer, .canceled: .gray
        }
    }

    var displayLabel: String {
        switch self {
        case .completed: "Completed"
        case .failed: "Failed"
        case .declined: "Declined"
        case .noAnswer: "No answer"
        case .canceled: "Canceled"
        }
    }
}

extension CallLogEntry {
    /// A ring nobody answered or declined, shown like a missed call in the
    /// Phone app: red, whatever the reason.
    var isMissed: Bool { missedReason != nil }

    var iconName: String {
        isMissed ? "phone.arrow.down.left" : outcome.iconName(for: direction)
    }

    var tint: Color {
        isMissed ? .red : outcome.tint
    }

    /// The outcome label, qualified with WHY when a failed call recorded a
    /// reason ("Failed — authentication") or a missed ring never rang
    /// ("Missed — Focus"). Shared by Recents and Agent Detail.
    var outcomeDisplayLabel: String {
        if let missedReason {
            return missedReason.shortLabel.map { "Missed — \($0)" } ?? "Missed"
        }
        if outcome == .failed, let short = failureReason?.shortLabel {
            return "Failed — \(short)"
        }
        return outcome.displayLabel
    }
}
