//
//  AgentColorTests.swift
//  ConduitTests
//
//  The per-agent identity palette and how an Agent resolves its color: the
//  name-derived slot is deterministic and only ever a curated case; a stored token
//  wins; a legacy nil token (pre-field migration) falls back to the name slot; and
//  a stored color is frozen against renames.
//

import Foundation
import Testing
@testable import Conduit

struct AgentColorTests {
    @Test func derivedColorIsDeterministic() {
        #expect(AgentColor.derived(forName: "Jarvis") == AgentColor.derived(forName: "Jarvis"))
        #expect(AgentColor.derived(forName: "Echo Bot") == AgentColor.derived(forName: "Echo Bot"))
    }

    @Test func derivedColorOnlyUsesThePalette() {
        // Every name lands on a curated case — never an out-of-range index, and
        // brown/gray/yellow aren't in the set, so they can't appear.
        for name in ["Jarvis", "Echo Bot", "Devil's Advocate", "loopback", "", "🤖", "Z"] {
            #expect(AgentColor.allCases.contains(AgentColor.derived(forName: name)))
        }
    }

    @Test func emptyNameResolvesToTheFirstSlot() {
        // Scalar sum is 0 → first slot; the modulo never traps.
        #expect(AgentColor.derived(forName: "") == AgentColor.allCases[0])
    }

    @Test func rawValueRoundTrips() {
        for color in AgentColor.allCases {
            #expect(AgentColor(rawValue: color.rawValue) == color)
        }
    }
}

@MainActor
struct AgentPaletteColorTests {
    @Test func initStampsAConcreteTokenFromTheName() {
        let agent = Agent(name: "Jarvis", transportKind: .daily)
        #expect(agent.colorTokenRaw != nil)
        #expect(agent.paletteColor == .derived(forName: "Jarvis"))
    }

    @Test func explicitTokenIsHonored() {
        let agent = Agent(name: "Jarvis", colorToken: .teal, transportKind: .daily)
        #expect(agent.colorTokenRaw == AgentColor.teal.rawValue)
        #expect(agent.paletteColor == .teal)
    }

    @Test func legacyNilTokenFallsBackToTheName() {
        // Simulate an agent that predates the field by clearing the token.
        let agent = Agent(name: "Jarvis", transportKind: .daily)
        agent.colorTokenRaw = nil
        #expect(agent.paletteColor == .derived(forName: "Jarvis"))
    }

    @Test func storedColorIsFrozenAgainstRenames() {
        let agent = Agent(name: "Jarvis", colorToken: .indigo, transportKind: .daily)
        agent.name = "Vision"
        #expect(agent.paletteColor == .indigo)
    }
}
