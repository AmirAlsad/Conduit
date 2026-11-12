//
//  SpeechSpokenStateAnnouncerTests.swift
//  ConduitTests
//
//  The real announcer's timing, with its ringback, synthesizer and sleep replaced:
//  the ringback starts a moment after the connecting cue (never, for a call that
//  stops or ends first), a stop silences it at once (the engine holds the call
//  connecting until its first tone is done), and an ended call cuts speech off in
//  the middle and runs the phrase's completion.
//

import AVFoundation
import Foundation
import Testing
@testable import Conduit

@MainActor
private final class RecordingRingback: RingbackPlaying {
    private(set) var starts = 0
    private(set) var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

/// A synthesizer that speaks nothing: it records what it was asked to do.
private final class SilentSynthesizer: AVSpeechSynthesizer {
    private(set) var spoken: [String] = []
    private(set) var immediateStops = 0

    override func speak(_ utterance: AVSpeechUtterance) {
        spoken.append(utterance.speechString)
    }

    override func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        if boundary == .immediate { immediateStops += 1 }
        return true
    }
}

/// A sleep that ends when the test says so.
@MainActor
private final class HeldSleep {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var requested: [Duration] = []

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { waiting.append($0) }
    }

    func endAll() {
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
    }
}

@MainActor
struct SpeechSpokenStateAnnouncerTests {
    private let ringback = RecordingRingback()
    private let synthesizer = SilentSynthesizer()
    private let sleeper = HeldSleep()

    private func announcer() -> SpeechSpokenStateAnnouncer {
        let sleeper = sleeper
        return SpeechSpokenStateAnnouncer(
            synthesizer: synthesizer,
            ringback: ringback,
            sleep: { await sleeper.sleep($0) }
        )
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func theRingbackStartsHalfASecondAfterTheConnectingCue() async {
        let announcer = announcer()
        announcer.startRepeating(.connecting)
        await settle()
        #expect(ringback.starts == 0)
        #expect(sleeper.requested == [Ringback.startDelay])

        sleeper.endAll()
        await settle()

        #expect(ringback.starts == 1)
        #expect(synthesizer.spoken.isEmpty) // connecting rings; it is not spoken
    }

    @Test func aCueThatStopsWithinTheDelayNeverRings() async {
        let announcer = announcer()
        announcer.startRepeating(.connecting)
        await settle()

        announcer.stopRepeating() // e.g. a hold, or a pre-empting state change
        sleeper.endAll()
        await settle()

        #expect(ringback.starts == 0)
    }

    @Test func aCallThatEndsWithinTheDelayNeverRings() async {
        let announcer = announcer()
        announcer.startRepeating(.connecting)
        await settle()

        announcer.stopNow()
        sleeper.endAll()
        await settle()

        #expect(ringback.starts == 0)
    }

    @Test func aStopSilencesTheRingbackAtOnce() async {
        let announcer = announcer()
        announcer.startRepeating(.connecting)
        await settle()
        sleeper.endAll()
        await settle()
        #expect(ringback.starts == 1)

        announcer.stopRepeating()

        #expect(ringback.stops >= 1)
        announcer.announce(.connected)
        #expect(synthesizer.spoken == [SpokenPhrase.connected.utterance]) // at once, no tail to wait out
    }

    @Test func anEndedCallCutsOffSpeechInProgressAndRunsItsCompletion() async {
        let announcer = announcer()
        var finished = 0
        announcer.announce(.connected) { finished += 1 }
        #expect(synthesizer.spoken == [SpokenPhrase.connected.utterance])
        #expect(finished == 0)

        announcer.stopNow()

        #expect(synthesizer.immediateStops == 1)
        #expect(finished == 1)
        await settle()
        #expect(finished == 1) // a late cancel callback runs nothing again
    }

    @Test func theRetryingLoopDoesNotCutOffTheDisconnectedBeforeIt() async {
        let announcer = announcer()
        announcer.announce(.disconnected)

        announcer.startRepeating(.retrying)

        #expect(synthesizer.immediateStops == 0)
        #expect(synthesizer.spoken == [SpokenPhrase.disconnected.utterance, SpokenPhrase.retrying.utterance])
    }
}
