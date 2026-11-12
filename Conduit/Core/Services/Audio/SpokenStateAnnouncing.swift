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
    /// Speak a phrase once. `completion` runs once, on the main actor, when the
    /// phrase has finished playing or will not play (stopped, or replaced before it
    /// started). A phrase announced while a ringback finishes plays after it, so
    /// then `completion` means both are done.
    func announce(_ phrase: SpokenPhrase, completion: (@MainActor () -> Void)?)
    /// Speak a phrase now and repeat it on a fixed cadence until stopped.
    func startRepeating(_ phrase: SpokenPhrase)
    /// Stop any repeating announcement. A ringback that has not yet rung for its
    /// minimum length keeps ringing until it has, and a phrase announced meanwhile
    /// is spoken when it stops, so a call that connects at once still rings once.
    func stopRepeating()
    /// Silence everything immediately: the call is over.
    func stopNow()
}

extension SpokenStateAnnouncing {
    /// Speak a phrase once, with nothing to run when it is done.
    func announce(_ phrase: SpokenPhrase) {
        announce(phrase, completion: nil)
    }
}
