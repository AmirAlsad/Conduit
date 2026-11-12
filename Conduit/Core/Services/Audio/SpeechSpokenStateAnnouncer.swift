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
//  The `.connecting` state plays a phone ringback tone instead of speaking. iOS
//  suppresses ordinary app audio (`AVAudioPlayer`) inside a CallKit VoIP session,
//  so the tone rides the privileged system-sound server (`AudioServices`) — the
//  same class of path that lets the spoken cues through during a call. No
//  `AVAudioSession` is touched (CallKit owns it).
//

import AudioToolbox
import AVFoundation
import Foundation

@MainActor
final class SpeechSpokenStateAnnouncer: SpokenStateAnnouncing {
    private let synthesizer = AVSpeechSynthesizer()
    private let repeatInterval: Duration
    /// The audible part of one `phone-ring.caf` cycle, so a ringback is never cut
    /// off mid-tone by a call that connects faster than one ring.
    private let minimumRingback: Duration
    private let clock = ContinuousClock()
    private var repeatTask: Task<Void, Never>?
    private var ringSoundID: SystemSoundID = 0
    private var isRinging = false
    private var ringStartedAt: ContinuousClock.Instant?
    private var ringFinishTask: Task<Void, Never>?
    private var phraseAfterRingback: SpokenPhrase?

    init(repeatInterval: Duration = .seconds(7), minimumRingback: Duration = .milliseconds(2100)) {
        self.repeatInterval = repeatInterval
        self.minimumRingback = minimumRingback
        synthesizer.usesApplicationAudioSession = false
    }

    func announce(_ phrase: SpokenPhrase) {
        guard ringFinishTask == nil else {
            phraseAfterRingback = phrase
            return
        }
        speak(phrase)
    }

    func startRepeating(_ phrase: SpokenPhrase) {
        stopNow()
        // A dialing call should sound like a call: ring (looped) for `.connecting`
        // instead of speaking it. Other states stay spoken.
        if phrase == .connecting {
            startRingback()
            return
        }
        speak(phrase)
        repeatTask = Task { [weak self, repeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: repeatInterval)
                guard !Task.isCancelled else { return }
                self?.speak(phrase)
            }
        }
    }

    func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
        guard isRinging, ringFinishTask == nil else { return }
        let remaining = ringStartedAt.map { minimumRingback - $0.duration(to: clock.now) } ?? .zero
        guard remaining > .zero else {
            stopRingback()
            return
        }
        ringFinishTask = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled, let self else { return }
            self.ringFinishTask = nil
            self.stopRingback()
            if let phrase = self.phraseAfterRingback {
                self.phraseAfterRingback = nil
                self.speak(phrase)
            }
        }
    }

    func stopNow() {
        ringFinishTask?.cancel()
        ringFinishTask = nil
        phraseAfterRingback = nil
        repeatTask?.cancel()
        repeatTask = nil
        stopRingback()
    }

    private func speak(_ phrase: SpokenPhrase) {
        let utterance = AVSpeechUtterance(string: phrase.utterance)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        Log.info(.audio, "Spoke call state: \(phrase.rawValue)")
    }

    // MARK: - Ringback (system sound)

    private func startRingback() {
        guard ringSoundID == 0 else { return }
        guard let url = Bundle.main.url(forResource: "phone-ring", withExtension: "caf") else {
            Log.error(.audio, "phone-ring.caf missing from bundle")
            return
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
        guard status == noErr else {
            Log.error(.audio, "Ringback system sound create failed: \(status)")
            return
        }
        ringSoundID = id
        isRinging = true
        ringStartedAt = clock.now
        playRingCycle()
        Log.info(.audio, "Playing ringback for call state: connecting")
    }

    /// Loop the ring by replaying each time the cycle finishes, until stopped.
    private func playRingCycle() {
        guard isRinging, ringSoundID != 0 else { return }
        AudioServicesPlaySystemSoundWithCompletion(ringSoundID) { [weak self] in
            Task { @MainActor in self?.playRingCycle() }
        }
    }

    private func stopRingback() {
        isRinging = false
        ringStartedAt = nil
        guard ringSoundID != 0 else { return }
        // Disposing halts an in-flight play immediately, so the tone never overlaps
        // the spoken "Connected" cue.
        AudioServicesDisposeSystemSoundID(ringSoundID)
        ringSoundID = 0
    }
}
