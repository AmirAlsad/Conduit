//
//  SpokenStateAnnouncing.swift
//  Conduit
//
//  The seam over spoken connection-state announcements. AgentCallHost drives it
//  from the engine's call cues; the real implementation uses `AVSpeechSynthesizer`,
//  the fake records phrases for tests. Decoupled from the agent's audio — it never
//  touches the transport.
//

import Foundation

@MainActor
protocol SpokenStateAnnouncing: AnyObject {
    /// Speak a phrase once, after any phrase still being spoken. `completion` runs
    /// once, on the main actor, when the phrase has finished playing or will not
    /// play (cut off by `stopNow()`).
    func announce(_ phrase: SpokenPhrase, completion: (@MainActor () -> Void)?)
    /// Repeat a phrase on a fixed cadence until stopped, starting now; `.connecting`
    /// loops the ringback instead, starting `Ringback.startDelay` from now.
    func startRepeating(_ phrase: SpokenPhrase)
    /// Stop the repeating announcement, or the ringback, at once; a ringback still
    /// waiting to start never starts. A phrase being spoken finishes.
    func stopRepeating()
    /// Silence everything immediately, a phrase being spoken included: the call is
    /// over. Every pending completion runs.
    func stopNow()
}

extension SpokenStateAnnouncing {
    /// Speak a phrase once, with nothing to run when it is done.
    func announce(_ phrase: SpokenPhrase) {
        announce(phrase, completion: nil)
    }
}
