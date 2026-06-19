//
//  AgentColor.swift
//  Conduit
//
//  The curated per-agent identity palette: a small set of iOS system colors —
//  already calibrated, vibrant, and accessible — spread around the wheel so
//  adjacent agents look distinct. Brown, gray, and yellow are deliberately
//  excluded (muddy, reads as "no color," and fails white-text contrast).
//
//  Stored as a stable token (the case's raw string), never a raw RGBA, so an
//  agent keeps its identity even if a slot's hex is ever retuned.
//
//  Resolved against a FIXED dark trait everywhere it's drawn, so a given agent's
//  color looks identical regardless of the device's light/dark setting — its
//  identity stays put even as the surrounding surface (e.g. the call screen)
//  follows the system appearance.
//

import SwiftUI

enum AgentColor: String, CaseIterable, Sendable {
    case red, orange, green, teal, blue, indigo, purple, pink

    var color: Color { Color(uiColor: uiColor) }

    var uiColor: UIColor {
        base.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
    }

    private var base: UIColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        }
    }

    /// A deterministic palette slot from a name (stable across launches — sums the
    /// name's scalars, NOT `hashValue`, which is seeded per process).
    static func derived(forName name: String) -> AgentColor {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return allCases[sum % allCases.count]
    }
}
