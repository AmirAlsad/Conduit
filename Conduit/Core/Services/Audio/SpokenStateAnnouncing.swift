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
    /// play: cut off by `cutOffPending()` or `stopNow()`, or not started by the
    /// synthesizer in time (the real announcer then cuts off everything queued).
    func announce(_ phrase: SpokenPhrase, completion: (@MainActor () -> Void)?)
    /// Repeat a phrase on a fixed cadence until stopped, starting now; `.connecting`
    /// loops the ringback instead, starting `Ringback.startDelay` from now.
    func startRepeating(_ phrase: SpokenPhrase)
    /// Stop the repeating announcement, or the ringback, at once; a ringback still
    /// waiting to start never starts. A phrase being spoken finishes.
    func stopRepeating()
    /// Cut off every phrase still queued or being spoken, running their
    /// completions; a repeating announcement keeps its cadence and the ringback
    /// plays on. For a phrase whose moment makes the earlier ones stale.
    func cutOffPending()
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
