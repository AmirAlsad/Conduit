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
//  The `.connecting` state plays a phone ringback (`Ringback`) instead of speaking,
//  starting `Ringback.startDelay` after the cue. The call engine keeps the call
//  connecting long enough for the first tone (`Ringback.minimumConnectingDuration`),
//  so a stop always comes after it and stops the ringback at once.
//
//  An announcement's completion runs when the synthesizer reports its utterance
//  finished or cancelled, or when `stopNow()` cuts it off, so the host knows when
//  the call's mic can open without the agent hearing the cue.
//

import AVFoundation
import Foundation

@MainActor
final class SpeechSpokenStateAnnouncer: NSObject, SpokenStateAnnouncing, AVSpeechSynthesizerDelegate {
    private let synthesizer: AVSpeechSynthesizer
    private let ringback: RingbackPlaying
    private let repeatInterval: Duration
    private let ringbackDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var repeatTask: Task<Void, Never>?
    /// The wait before the ringback starts; cancelling it means it never starts.
    private var ringbackStart: Task<Void, Never>?
    /// The utterances whose end someone is waiting for. Each entry keeps its
    /// utterance alive, so its identifier is not reused before the entry goes.
    private var utteranceCompletions: [ObjectIdentifier: (utterance: AVSpeechUtterance, completion: @MainActor () -> Void)] = [:]

    init(
        repeatInterval: Duration = .seconds(7),
        ringbackDelay: Duration = Ringback.startDelay,
        synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(),
        ringback: RingbackPlaying? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.repeatInterval = repeatInterval
        self.ringbackDelay = ringbackDelay
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
        // Not `stopNow()`: a phrase already announced (a "Disconnected" before the
        // retrying loop) still plays, and the loop's first phrase follows it.
        stopRepeating()
        // A dialing call should sound like a call: ring (looped) for `.connecting`
        // instead of speaking it. Other states stay spoken.
        if phrase == .connecting {
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
        speak(phrase)
        let sleep = sleep
        repeatTask = Task { [weak self, repeatInterval] in
            while !Task.isCancelled {
                try? await sleep(repeatInterval)
                guard !Task.isCancelled else { return }
                self?.speak(phrase)
            }
        }
    }

    func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
        ringbackStart?.cancel()
        ringbackStart = nil
        ringback.stop()
    }

    func stopNow() {
        stopRepeating()
        // Every phrase is cut off, so every completion is due now; the
        // synthesizer's late cancel callbacks then find nothing left to run.
        let cutOff = utteranceCompletions.values.map(\.completion)
        utteranceCompletions = [:]
        synthesizer.stopSpeaking(at: .immediate)
        cutOff.forEach { $0() }
    }

    private func speak(_ phrase: SpokenPhrase, completion: (@MainActor () -> Void)? = nil) {
        let utterance = AVSpeechUtterance(string: phrase.utterance)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let completion {
            utteranceCompletions[ObjectIdentifier(utterance)] = (utterance, completion)
        }
        synthesizer.speak(utterance)
        Log.info(.audio, "Spoke call state: \(phrase.rawValue)")
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        utteranceEnded(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        utteranceEnded(ObjectIdentifier(utterance))
    }

    private nonisolated func utteranceEnded(_ id: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let entry = self?.utteranceCompletions.removeValue(forKey: id) else { return }
            entry.completion()
        }
    }
}
