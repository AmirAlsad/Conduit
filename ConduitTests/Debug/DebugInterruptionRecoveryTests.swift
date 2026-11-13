//
//  DebugInterruptionRecoveryTests.swift
//  ConduitTests
//
//  The DEBUG recovery-after-a-phone-call settings as the engine and the transport
//  factory read them: the value Settings stores for each layer, and Off for nothing
//  stored or a value from another build.
//

import Foundation
import Testing
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngine
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngineDaily
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngineLiveKit
@testable import Conduit

struct DebugInterruptionRecoveryTests {
    private func defaults(_ values: [String: String?]) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "DebugInterruptionRecoveryTests.\(UUID().uuidString)"))
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    @Test(arguments: [
        ("off", SessionInterruptionRecovery.off), ("E-A", .reapplyCategory), ("E-B", .reapplyCategoryAndActivate),
    ])
    func readsTheSessionChoice(stored: String, expected: SessionInterruptionRecovery) throws {
        let defaults = try defaults([DebugInterruptionRecovery.sessionKey: stored])
        #expect(DebugInterruptionRecovery.session(in: defaults) == expected)
    }

    @Test(arguments: [
        ("off", LiveKitInterruptionRecovery.off), ("L-A", .restartEngine), ("L-B", .restartEngineUntilRunning),
        ("L-C", .notifyActivationThenRestart),
    ])
    func readsTheLiveKitChoice(stored: String, expected: LiveKitInterruptionRecovery) throws {
        let defaults = try defaults([DebugInterruptionRecovery.liveKitKey: stored])
        #expect(DebugInterruptionRecovery.liveKit(in: defaults) == expected)
    }

    @Test(arguments: [
        ("off", DailyInterruptionRecovery.off), ("A", .restartMedia), ("B", .reassertAudioDevice), ("C", .rejoin),
    ])
    func readsTheDailyChoice(stored: String, expected: DailyInterruptionRecovery) throws {
        let defaults = try defaults([DebugInterruptionRecovery.dailyKey: stored])
        #expect(DebugInterruptionRecovery.daily(in: defaults) == expected)
    }

    @Test(arguments: [nil, "a", "none", "D2", ""] as [String?])
    func anythingElseIsOff(stored: String?) throws {
        let defaults = try defaults([
            DebugInterruptionRecovery.sessionKey: stored,
            DebugInterruptionRecovery.liveKitKey: stored,
            DebugInterruptionRecovery.dailyKey: stored,
        ])
        #expect(DebugInterruptionRecovery.summary(in: defaults) == "session off, livekit off, daily off")
    }

    @Test func theSummaryNamesEachLayersChoice() throws {
        let defaults = try defaults([
            DebugInterruptionRecovery.sessionKey: "E-B",
            DebugInterruptionRecovery.liveKitKey: "L-A",
            DebugInterruptionRecovery.dailyKey: "C",
        ])
        #expect(DebugInterruptionRecovery.summary(in: defaults) == "session E-B, livekit L-A, daily C")
    }
}
