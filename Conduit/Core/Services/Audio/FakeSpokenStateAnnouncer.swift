//
//  FakeSpokenStateAnnouncer.swift
//  Conduit
//
//  In-app fake conforming to `SpokenStateAnnouncing`. Records what was spoken so
//  tests can assert the right phrases fire at the right transitions. Nothing it
//  announces finishes by itself: a test finishes the phrases with
//  `finishAnnouncements()`, and `stopNow()` cuts them off, as the real one does.
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
    private(set) var stopNowCount = 0
    private var pendingCompletions: [@MainActor () -> Void] = []
    /// How many announced phrases have a completion still to run.
    var unfinishedAnnouncementCount: Int { pendingCompletions.count }

    func announce(_ phrase: SpokenPhrase, completion: (@MainActor () -> Void)?) {
        announced.append(phrase)
        if let completion { pendingCompletions.append(completion) }
    }

    /// Every phrase announced so far has finished playing: run their completions,
    /// in the order the phrases were announced.
    func finishAnnouncements() {
        let completions = pendingCompletions
        pendingCompletions = []
        completions.forEach { $0() }
    }

    /// The oldest phrase still playing has finished: run its completion only.
    func finishOldestAnnouncement() {
        guard !pendingCompletions.isEmpty else { return }
        pendingCompletions.removeFirst()()
    }

    func startRepeating(_ phrase: SpokenPhrase) {
        startedRepeating.append(phrase)
        repeatingPhrase = phrase
    }

    func stopRepeating() {
        repeatingPhrase = nil
        stopRepeatingCount += 1
    }

    func stopNow() {
        repeatingPhrase = nil
        stopNowCount += 1
        finishAnnouncements() // cut off, as the real one does
    }
}
