//
//  SpeechSpokenStateAnnouncer.swift
//  Conduit
//
//  Real `SpokenStateAnnouncing` over `AVSpeechSynthesizer`. The voice is
//  deliberately the stock synthesizer one — distinct from the agent's — because
//  this status is external to the conversation.
//
//  The synthesizer speaks through the system's own speech session
//  (`usesApplicationAudioSession = false`), not the app's. On a device, speech in
//  the app's session was inaudible throughout a Daily call, while speech in the
//  system's session was heard and left the call's session unchanged.
//
//  Repeating `.connecting` plays a phone ringback (`Ringback`) instead of speaking,
//  starting `Ringback.startDelay` after the cue; the host repeats it only for a call
//  the user placed, and the ringback is told to prepare at the cue itself. The call
//  engine keeps such a call connecting long enough for the first tone
//  (`Ringback.minimumOutgoingConnectingDuration`), so a stop always comes after it
//  and stops the ringback at once. Announced once, `.connecting` is spoken
//  ("Connecting").
//
//  An announcement's completion runs when the synthesizer reports its utterance
//  finished or cancelled, or when it is cut off, so the host knows when the call's
//  mic can open without the agent hearing the cue. A phrase the synthesizer has not
//  started within `startBound` of the request is stale: everything still queued or
//  speaking is cut off then, so it is never heard after its moment and its
//  completion cannot wait on a stalled synthesizer. After a LiveKit reconnect on a
//  device, "Connected" did not finish within 5 s; why is not known.
//

import AVFoundation
import Foundation

@MainActor
final class SpeechSpokenStateAnnouncer: NSObject, SpokenStateAnnouncing, AVSpeechSynthesizerDelegate {
    /// How long a requested phrase may wait for the synthesizer to start it.
    nonisolated static let defaultStartBound: Duration = .milliseconds(1500)

    private let synthesizer: AVSpeechSynthesizer
    private let ringback: RingbackPlaying
    private let repeatInterval: Duration
    private let ringbackDelay: Duration
    private let startBound: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var repeatTask: Task<Void, Never>?
    /// The wait before the ringback starts; cancelling it means it never starts.
    private var ringbackStart: Task<Void, Never>?
    /// Every utterance requested and not yet finished, cancelled or cut off. Each
    /// entry keeps its utterance alive, so its identifier is not reused before the
    /// entry goes.
    private var pending: [ObjectIdentifier: Pending] = [:]
    /// The repeating loop's latest utterance; no repeat is queued behind it.
    private var lastRepeat: ObjectIdentifier?
    #if DEBUG
    /// DEBUG: each phrase's request, start, finish, cancel and cut-off (the call trace).
    var trace: ((String) -> Void)?
    #endif

    private struct Pending {
        let utterance: AVSpeechUtterance
        let phrase: SpokenPhrase
        let completion: (@MainActor () -> Void)?
        var hasStarted = false
        var startDeadline: Task<Void, Never>?
    }

    init(
        repeatInterval: Duration = .seconds(7),
        ringbackDelay: Duration = Ringback.startDelay,
        startBound: Duration = SpeechSpokenStateAnnouncer.defaultStartBound,
        synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(),
        ringback: RingbackPlaying? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.repeatInterval = repeatInterval
        self.ringbackDelay = ringbackDelay
        self.startBound = startBound
        self.synthesizer = synthesizer
        self.ringback = ringback ?? SystemRingback()
        self.sleep = sleep
        super.init()
        synthesizer.usesApplicationAudioSession = false
        synthesizer.delegate = self
    }

    func announce(_ phrase: SpokenPhrase, completion: (@MainActor () -> Void)?) {
        speak(phrase, completion: completion)
    }

    func startRepeating(_ phrase: SpokenPhrase) {
        // Not a cut-off: a phrase already announced (a "Disconnected" before the
        // retrying loop) still plays, and the loop's first phrase follows it.
        stopRepeating()
        // A dialing call should sound like a call: ring (looped) for `.connecting`
        // instead of speaking it. Other states stay spoken.
        if phrase == .connecting {
            ringback.prepare()
            let sleep = sleep
            let delay = ringbackDelay
            ringbackStart = Task { [weak self] in
                try? await sleep(delay)
                guard !Task.isCancelled, let self else { return }
                self.ringbackStart = nil
                self.ringback.start()
            }
            return
        }
        lastRepeat = speak(phrase)
        let sleep = sleep
        repeatTask = Task { [weak self, repeatInterval] in
            while !Task.isCancelled {
                try? await sleep(repeatInterval)
                guard !Task.isCancelled, let self else { return }
                self.repeatIfPreviousFinished(phrase)
            }
        }
    }

    func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
        lastRepeat = nil
        ringbackStart?.cancel()
        ringbackStart = nil
        ringback.stop()
    }

    func cutOffPending() {
        guard !pending.isEmpty else { return }
        let cut = pending.values
        pending = [:]
        // Every phrase is cut off, so every completion is due now; the
        // synthesizer's late cancel callbacks then find nothing left to run.
        synthesizer.stopSpeaking(at: .immediate)
        for entry in cut {
            entry.startDeadline?.cancel()
            trace("cut off \(entry.phrase.rawValue)\(entry.hasStarted ? "" : " (never started)")")
            entry.completion?()
        }
    }

    func stopNow() {
        stopRepeating()
        cutOffPending()
    }

    @discardableResult
    private func speak(_ phrase: SpokenPhrase, completion: (@MainActor () -> Void)? = nil) -> ObjectIdentifier {
        let utterance = AVSpeechUtterance(string: phrase.utterance)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let id = ObjectIdentifier(utterance)
        let sleep = sleep
        let bound = startBound
        let deadline = Task { [weak self] in
            try? await sleep(bound)
            guard !Task.isCancelled else { return }
            self?.startBoundPassed(id)
        }
        pending[id] = Pending(utterance: utterance, phrase: phrase, completion: completion, startDeadline: deadline)
        trace("request \(phrase.rawValue)")
        synthesizer.speak(utterance)
        Log.info(.audio, "Spoke call state: \(phrase.rawValue)")
        return id
    }

    private func repeatIfPreviousFinished(_ phrase: SpokenPhrase) {
        if let lastRepeat, pending[lastRepeat] != nil {
            trace("repeat of \(phrase.rawValue) skipped: the previous one has not finished")
            return
        }
        lastRepeat = speak(phrase)
    }

    /// The phrase has not started within `startBound`: its moment has passed.
    private func startBoundPassed(_ id: ObjectIdentifier) {
        guard let entry = pending[id], !entry.hasStarted else { return }
        Log.warning(.audio, "Call state \(entry.phrase.rawValue) did not start within \(startBound); cutting off what is queued")
        trace("\(entry.phrase.rawValue) not started within \(startBound); cutting off")
        cutOffPending()
    }

    private func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
        trace?("speech: \(line())")
        #endif
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceStarted(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceEnded(id, how: "didFinish") }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceEnded(id, how: "didCancel") }
    }

    private func utteranceStarted(_ id: ObjectIdentifier) {
        guard var entry = pending[id] else { return }
        entry.hasStarted = true
        entry.startDeadline?.cancel()
        entry.startDeadline = nil
        pending[id] = entry
        trace("didStart \(entry.phrase.rawValue)")
    }

    private func utteranceEnded(_ id: ObjectIdentifier, how: String) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.startDeadline?.cancel()
        trace("\(how) \(entry.phrase.rawValue)")
        entry.completion?()
    }
}
