//
//  SpokenStateAnnouncing.swift
//  Conduit
//
//  The seam over spoken connection-state announcements. The coordinator drives it
//  on connection-state changes; the real implementation uses `AVSpeechSynthesizer`,
//  the fake records phrases for tests. Decoupled from the agent's audio — it never
//  touches the transport.
//

import Foundation

@MainActor
protocol SpokenStateAnnouncing: AnyObject {
    /// Speak a phrase once.
    func announce(_ phrase: SpokenPhrase)
    /// Speak a phrase now and repeat it on a fixed cadence until stopped.
    func startRepeating(_ phrase: SpokenPhrase)
    /// Stop any repeating announcement.
    func stopRepeating()
}
