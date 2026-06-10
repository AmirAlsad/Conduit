//
//  AgentNameMatcherTests.swift
//  ConduitTests
//
//  The tiered spoken-name resolution behind Siri dialing: exact beats prefix
//  beats word-boundary contains; ties within a tier surface as ambiguity.
//

import Foundation
import Testing
@testable import Conduit

struct AgentNameMatcherTests {

    private func candidate(_ name: String) -> AgentNameMatcher.Candidate {
        AgentNameMatcher.Candidate(id: UUID(), name: name)
    }

    @Test func exactMatchWins() {
        let marvin = candidate("Marvin")
        let twin = candidate("Marvin's Twin")
        let result = AgentNameMatcher.match("Marvin", in: [twin, marvin])
        #expect(result == .unique(marvin))
    }

    @Test func matchIsCaseInsensitive() {
        let agent = candidate("Ethereal Castle")
        #expect(AgentNameMatcher.match("ethereal castle", in: [agent]) == .unique(agent))
    }

    @Test func matchFoldsDiacritics() {
        let agent = candidate("Café Bot")
        #expect(AgentNameMatcher.match("cafe bot", in: [agent]) == .unique(agent))
    }

    @Test func prefixMatchesWhenNoExact() {
        let agent = candidate("Ethereal Castle")
        #expect(AgentNameMatcher.match("Ethereal", in: [agent]) == .unique(agent))
    }

    @Test func wordBoundaryContainsMatches() {
        let agent = candidate("Ethereal Castle")
        #expect(AgentNameMatcher.match("Castle", in: [agent]) == .unique(agent))
    }

    @Test func midWordFragmentDoesNotMatch() {
        let agent = candidate("Ethereal Castle")
        #expect(AgentNameMatcher.match("stle", in: [agent]) == .none)
    }

    @Test func sharedPrefixIsAmbiguous() {
        let a = candidate("Marvin Home")
        let b = candidate("Marvin Work")
        let result = AgentNameMatcher.match("Marvin", in: [a, b])
        #expect(result == .ambiguous([a, b]))
    }

    @Test func noMatch() {
        #expect(AgentNameMatcher.match("Jarvis", in: [candidate("Marvin")]) == .none)
    }

    @Test func emptyAndWhitespaceQueriesMatchNothing() {
        let agent = candidate("Marvin")
        #expect(AgentNameMatcher.match("", in: [agent]) == .none)
        #expect(AgentNameMatcher.match("   ", in: [agent]) == .none)
    }

    @Test func queryWhitespaceIsTrimmed() {
        let agent = candidate("Marvin")
        #expect(AgentNameMatcher.match("  Marvin ", in: [agent]) == .unique(agent))
    }
}
