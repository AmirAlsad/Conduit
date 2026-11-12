//
//  DebugDailyRingJoinTests.swift
//  ConduitTests
//
//  The DEBUG ring-join setting as the Daily transport factory reads it: the value
//  Settings stores, and Off for nothing stored or a value from another build.
//

import Foundation
import Testing
@testable import Conduit

struct DebugDailyRingJoinTests {
    private func defaults(storing value: String?) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "DebugDailyRingJoinTests.\(UUID().uuidString)"))
        defaults.set(value, forKey: DebugDailyRingJoin.defaultsKey)
        return defaults
    }

    @Test(arguments: [
        ("off", DebugDailyRingJoin.off), ("D1", .d1), ("D2", .d2), ("D3", .d3),
    ])
    func readsTheStoredChoice(stored: String, expected: DebugDailyRingJoin) throws {
        #expect(DebugDailyRingJoin.current(in: try defaults(storing: stored)) == expected)
    }

    @Test(arguments: [nil, "d2", "none", ""] as [String?])
    func anythingElseIsOff(stored: String?) throws {
        #expect(DebugDailyRingJoin.current(in: try defaults(storing: stored)) == .off)
    }
}
