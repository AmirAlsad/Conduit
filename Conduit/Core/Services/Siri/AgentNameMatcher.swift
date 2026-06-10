//
//  AgentNameMatcher.swift
//  Conduit
//
//  Resolves a spoken/typed name to an agent for Siri dialing. Pure logic — no
//  SwiftData, no AppIntents — so the tiering is unit-tested at sim speed and
//  shared by both Siri layers (the App Intents entity query and the SiriKit
//  contact resolution).
//

import Foundation

enum AgentNameMatcher {
    struct Candidate: Equatable, Sendable {
        let id: UUID
        let name: String
    }

    enum Result: Equatable, Sendable {
        case none
        case unique(Candidate)
        case ambiguous([Candidate])
    }

    /// Tiered match: exact → prefix → word-boundary contains. The first
    /// non-empty tier wins, so "Marvin" prefers an agent named exactly Marvin
    /// over "Marvin's Twin". All comparison is case- and diacritic-folded.
    static func match(_ query: String, in candidates: [Candidate]) -> Result {
        let folded = fold(query)
        guard !folded.isEmpty else { return .none }

        let exact = candidates.filter { fold($0.name) == folded }
        if let result = tier(exact) { return result }

        let prefix = candidates.filter { fold($0.name).hasPrefix(folded) }
        if let result = tier(prefix) { return result }

        let contains = candidates.filter { wordBoundaryContains(fold($0.name), folded) }
        if let result = tier(contains) { return result }

        return .none
    }

    private static func tier(_ matches: [Candidate]) -> Result? {
        switch matches.count {
        case 0: return nil
        case 1: return .unique(matches[0])
        default: return .ambiguous(matches)
        }
    }

    private static func fold(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// True when `query` starts at some word boundary of `name`
    /// ("Castle" matches "Ethereal Castle"; "stle" does not).
    private static func wordBoundaryContains(_ name: String, _ query: String) -> Bool {
        let words = name.split(separator: " ")
        for start in words.indices {
            if words[start...].joined(separator: " ").hasPrefix(query) {
                return true
            }
        }
        return false
    }
}
