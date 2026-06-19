//
//  SpeechSpokenStateAnnouncer.swift
//  Conduit
//
//  Real `SpokenStateAnnouncing` over `AVSpeechSynthesizer`. The voice is
//  deliberately the stock synthesizer one — distinct from the agent's — because
//  this status is external to the conversation.
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
    private var repeatTask: Task<Void, Never>?
    private var ringSoundID: SystemSoundID = 0
    private var isRinging = false

    init(repeatInterval: Duration = .seconds(7)) {
        self.repeatInterval = repeatInterval
    }

    func announce(_ phrase: SpokenPhrase) {
        speak(phrase)
    }

    func startRepeating(_ phrase: SpokenPhrase) {
        stopRepeating()
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
        stopRingback()
    }

    private func speak(_ phrase: SpokenPhrase) {
        // The call audio session is owned by CallKit; this announcer must mix with
        // it and never deactivate it. The session/ducking wiring is finalized with
        // the audio-session work (WS-3); here it speaks into the active session.
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
        guard ringSoundID != 0 else { return }
        // Disposing halts an in-flight play immediately, so the tone never overlaps
        // the spoken "Connected" cue.
        AudioServicesDisposeSystemSoundID(ringSoundID)
        ringSoundID = 0
    }
}
