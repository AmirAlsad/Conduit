//
//  SpeechSpokenStateAnnouncer.swift
//  Conduit
//
//  Real `SpokenStateAnnouncing` over `AVSpeechSynthesizer`. The voice is
//  deliberately the stock synthesizer one — distinct from the agent's — because
//  this status is external to the conversation.
//

import AVFoundation
import Foundation

@MainActor
final class SpeechSpokenStateAnnouncer: SpokenStateAnnouncing {
    private let synthesizer = AVSpeechSynthesizer()
    private let repeatInterval: Duration
    private var repeatTask: Task<Void, Never>?

    init(repeatInterval: Duration = .seconds(7)) {
        self.repeatInterval = repeatInterval
    }

    func announce(_ phrase: SpokenPhrase) {
        speak(phrase)
    }

    func startRepeating(_ phrase: SpokenPhrase) {
        stopRepeating()
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
}
