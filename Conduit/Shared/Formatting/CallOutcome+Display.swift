//
//  CallOutcome+Display.swift
//  Conduit
//
//  UI presentation for a call outcome (icon, tint, label), shared by the Recents
//  list and the per-agent call history. Lives in Shared (the UI layer) so Core
//  models stay free of SwiftUI.
//

import SwiftUI

extension CallOutcome {
    var iconName: String {
        switch self {
        case .completed: "phone.arrow.up.right"
        case .failed: "phone.down.fill"
        case .declined: "phone.down.fill"
        case .noAnswer: "phone.arrow.up.right"
        case .canceled: "phone.arrow.up.right"
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
