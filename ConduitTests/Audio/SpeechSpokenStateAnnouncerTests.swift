//
//  SpeechSpokenStateAnnouncerTests.swift
//  ConduitTests
//
//  The real announcer's timing, with its ringback, synthesizer and sleep replaced:
//  the ringback is prepared at the connecting cue and starts a moment after it
//  (never, for a call that stops or ends first), a stop silences it at once (the
//  engine holds the call connecting until its first tone is done), and an ended
//  call cuts speech off in
//  the middle and runs the phrase's completion. A phrase the synthesizer does not
//  start within the start bound is cut off with everything queued; a repeat never
//  queues behind an unfinished one. The synthesizer's callbacks are driven by hand.
//

import AVFoundation
import Foundation
import Testing
@testable import Conduit

@MainActor
private final class RecordingRingback: RingbackPlaying {
    private(set) var prepares = 0
    private(set) var starts = 0
    private(set) var stops = 0
    func prepare() { prepares += 1 }
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

/// A synthesizer that speaks nothing: it records what it was asked to do.
private final class SilentSynthesizer: AVSpeechSynthesizer {
    private(set) var spoken: [String] = []
    private(set) var utterances: [AVSpeechUtterance] = []
    private(set) var immediateStops = 0

    override func speak(_ utterance: AVSpeechUtterance) {
        spoken.append(utterance.speechString)
        utterances.append(utterance)
    }

    override func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        if boundary == .immediate { immediateStops += 1 }
        return true
    }
}

/// A sleep that ends when the test says so.
@MainActor
private final class HeldSleep {
    private var waiting: [(duration: Duration, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var requested: [Duration] = []

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { waiting.append((duration, $0)) }
    }

    func endAll() {
        let all = waiting
        waiting = []
        all.forEach { $0.continuation.resume() }
    }

    /// End the sleeps that asked for `duration`; the others go on.
    func end(_ duration: Duration) {
        let due = waiting.filter { $0.duration == duration }
        waiting.removeAll { $0.duration == duration }
        due.forEach { $0.continuation.resume() }
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

    private let bound = SpeechSpokenStateAnnouncer.defaultStartBound

    private func startSpeaking(_ announcer: SpeechSpokenStateAnnouncer, _ index: Int) async {
        announcer.speechSynthesizer(synthesizer, didStart: synthesizer.utterances[index])
        await settle()
    }

    private func finishSpeaking(_ announcer: SpeechSpokenStateAnnouncer, _ index: Int) async {
        announcer.speechSynthesizer(synthesizer, didFinish: synthesizer.utterances[index])
        await settle()
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func theRingbackStartsHalfASecondAfterTheConnectingCue() async {
        let announcer = announcer()
        announcer.startRepeating(.connecting)
        await settle()
        #expect(ringback.prepares == 1) // at the cue, ahead of the ring
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

    // MARK: - The start bound

    @Test func theStartBoundIsAboutASecondAndAHalf() {
        #expect(bound == .milliseconds(1500))
    }

    @Test func aPhraseNotStartedWithinTheBoundIsCutOffAndItsCompletionRuns() async {
        let announcer = announcer()
        var finished = 0
        announcer.announce(.connected) { finished += 1 }
        await settle()
        #expect(sleeper.requested == [bound])

        sleeper.end(bound)
        await settle()

        #expect(synthesizer.immediateStops == 1)
        #expect(finished == 1)
        await startSpeaking(announcer, 0) // a late start, then its cancel: nothing runs again
        announcer.speechSynthesizer(synthesizer, didCancel: synthesizer.utterances[0])
        await settle()
        #expect(finished == 1)
    }

    @Test func aPhraseThatStartsInTimeIsNotCutOff() async {
        let announcer = announcer()
        var finished = 0
        announcer.announce(.connected) { finished += 1 }
        await startSpeaking(announcer, 0)

        sleeper.end(bound)
        await settle()
        #expect(synthesizer.immediateStops == 0)
        #expect(finished == 0)

        await finishSpeaking(announcer, 0)
        #expect(finished == 1)
    }

    /// A phrase stuck behind one that never finishes is stale at the bound: both go.
    @Test func aPhraseQueuedBehindAStalledOneIsCutOffWithIt() async {
        let announcer = announcer()
        var completions: [SpokenPhrase] = []
        announcer.announce(.disconnected) { completions.append(.disconnected) }
        await startSpeaking(announcer, 0) // then stalls
        announcer.announce(.connecting) { completions.append(.connecting) }
        await settle()

        sleeper.end(bound)
        await settle()

        #expect(synthesizer.immediateStops == 1)
        #expect(Set(completions) == [.disconnected, .connecting])
    }

    // MARK: - Cutting off

    @Test func cuttingOffEndsWhatIsQueuedAndSpeakingButNotTheLoop() async {
        let announcer = announcer()
        var finished = 0
        announcer.announce(.disconnected) { finished += 1 }
        announcer.startRepeating(.retrying)
        await startSpeaking(announcer, 0)

        announcer.cutOffPending()

        #expect(synthesizer.immediateStops == 1)
        #expect(finished == 1)
        sleeper.end(.seconds(7)) // the loop's cadence goes on
        await settle()
        #expect(synthesizer.spoken.last == SpokenPhrase.retrying.utterance)
        #expect(synthesizer.spoken.count == 3)
    }

    @Test func cuttingOffNothingTouchesNothing() {
        let announcer = announcer()
        announcer.cutOffPending()
        #expect(synthesizer.immediateStops == 0)
    }

    // MARK: - Repeats

    /// A repeat never queues behind its previous utterance: the one due while the
    /// previous has not finished is skipped, and the next tick speaks again.
    @Test func aRepeatIsSkippedWhileThePreviousOneHasNotFinished() async {
        let announcer = announcer()
        announcer.startRepeating(.retrying)
        await startSpeaking(announcer, 0)
        await settle()
        #expect(synthesizer.spoken.count == 1)

        sleeper.end(.seconds(7))
        await settle()
        #expect(synthesizer.spoken.count == 1) // still speaking: not queued

        await finishSpeaking(announcer, 0)
        sleeper.end(.seconds(7))
        await settle()
        #expect(synthesizer.spoken.count == 2)
    }

    // MARK: - The call trace

    #if DEBUG
    @Test func eachPhrasesRequestStartFinishAndCutOffGoToTheTrace() async {
        let announcer = announcer()
        var lines: [String] = []
        announcer.trace = { lines.append($0) }
        announcer.announce(.connected)
        await startSpeaking(announcer, 0)
        await finishSpeaking(announcer, 0)
        announcer.announce(.disconnected)
        await settle()
        sleeper.end(bound)
        await settle()

        #expect(lines == [
            "speech: request connected",
            "speech: didStart connected",
            "speech: didFinish connected",
            "speech: request disconnected",
            "speech: disconnected not started within 1.5 seconds; cutting off",
            "speech: cut off disconnected (never started)",
        ])
    }
    #endif
}
