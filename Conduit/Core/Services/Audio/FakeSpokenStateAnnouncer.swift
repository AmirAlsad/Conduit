//
//  FakeSpokenStateAnnouncer.swift
//  Conduit
//
//  In-app fake conforming to `SpokenStateAnnouncing`. Records what was spoken so
//  tests can assert the right phrases fire at the right transitions.
//

import Foundation

@MainActor
final class FakeSpokenStateAnnouncer: SpokenStateAnnouncing {
    /// Every one-shot `announce(_:)` phrase, in order.
    private(set) var announced: [SpokenPhrase] = []
    /// Every `startRepeating(_:)` phrase, in order.
    private(set) var startedRepeating: [SpokenPhrase] = []
    /// The phrase currently repeating, if any.
    private(set) var repeatingPhrase: SpokenPhrase?
    private(set) var stopRepeatingCount = 0

    func announce(_ phrase: SpokenPhrase) {
        announced.append(phrase)
    }

    func startRepeating(_ phrase: SpokenPhrase) {
        startedRepeating.append(phrase)
        repeatingPhrase = phrase
    }

    func stopRepeating() {
        repeatingPhrase = nil
        stopRepeatingCount += 1
    }
}
