//
//  DebugRingbackTests.swift
//  ConduitTests
//
//  The DEBUG ringback switch: the method Settings stores (the system sound for
//  nothing stored or a value from another build), read at each ringing's start,
//  and a stop that reaches the ringback that was started even when the choice
//  changed meanwhile.
//

import Foundation
import Testing
@testable import Conduit

@MainActor
private final class RecordingRingback: RingbackPlaying {
    private(set) var calls: [String] = []
    func start() { calls.append("start") }
    func stop() { calls.append("stop") }
}

struct DebugRingbackMethodTests {
    private func defaults(storing value: String?) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "DebugRingbackMethodTests.\(UUID().uuidString)"))
        defaults.set(value, forKey: DebugRingbackMethod.defaultsKey)
        return defaults
    }

    @Test(arguments: [("systemSound", DebugRingbackMethod.systemSound), ("audioPlayer", .audioPlayer)])
    func readsTheStoredChoice(stored: String, expected: DebugRingbackMethod) throws {
        #expect(DebugRingbackMethod.current(in: try defaults(storing: stored)) == expected)
    }

    @Test(arguments: [nil, "AudioPlayer", "player", ""] as [String?])
    func anythingElseIsTheSystemSound(stored: String?) throws {
        #expect(DebugRingbackMethod.current(in: try defaults(storing: stored)) == .systemSound)
    }
}

@MainActor
struct DebugSwitchableRingbackTests {
    private let systemSound = RecordingRingback()
    private let audioPlayer = RecordingRingback()

    private final class Choice {
        var method = DebugRingbackMethod.systemSound
    }

    private let choice = Choice()

    private func ringback(trace: @escaping (String) -> Void = { _ in }) -> DebugSwitchableRingback {
        let choice = choice
        return DebugSwitchableRingback(
            method: { choice.method },
            systemSound: systemSound,
            audioPlayer: audioPlayer,
            describeSession: { "session" },
            trace: trace
        )
    }

    @Test(arguments: DebugRingbackMethod.allCases)
    func startsTheChosenMethodOnly(method: DebugRingbackMethod) {
        choice.method = method
        ringback().start()

        let (chosen, other) = method == .audioPlayer ? (audioPlayer, systemSound) : (systemSound, audioPlayer)
        #expect(chosen.calls == ["start"])
        #expect(other.calls.isEmpty)
    }

    @Test func readsTheChoiceAtEachStart() {
        let ringback = ringback()
        ringback.start()
        ringback.stop()

        choice.method = .audioPlayer
        ringback.start()

        #expect(systemSound.calls == ["start", "stop"])
        #expect(audioPlayer.calls == ["start"])
    }

    @Test func stopsTheRingbackItStartedAfterTheChoiceChanged() {
        let ringback = ringback()
        ringback.start()
        choice.method = .audioPlayer

        ringback.stop()

        #expect(systemSound.calls == ["start", "stop"])
        #expect(audioPlayer.calls.isEmpty)
    }

    @Test func aSecondStartWhileRingingStartsNothing() {
        let ringback = ringback()
        ringback.start()
        ringback.start()

        #expect(systemSound.calls == ["start"])
    }

    @Test func aStopWithNothingRingingDoesNothing() {
        var lines: [String] = []
        ringback(trace: { lines.append($0) }).stop()

        #expect(systemSound.calls.isEmpty)
        #expect(audioPlayer.calls.isEmpty)
        #expect(lines.isEmpty)
    }

    @Test func tracesTheMethodAndSessionAtTheStartAndTheStop() {
        var lines: [String] = []
        choice.method = .audioPlayer
        let ringback = ringback(trace: { lines.append($0) })
        ringback.start()
        ringback.stop()

        #expect(lines == ["ringback: start, method audioPlayer; session", "ringback: stop, method audioPlayer"])
    }
}
