//
//  FakeSpokenStateAnnouncer.swift
//  Conduit
//
//  In-app fake conforming to `SpokenStateAnnouncing`. Records what was spoken so
//  tests can assert the right phrases fire at the right transitions. Nothing it
//  announces finishes by itself: a test finishes the phrases with
//  `finishAnnouncements()`, and `cutOffPending()` and `stopNow()` cut them off, as
//  the real one does. A phrase is requested, not started, until `startAnnouncements()`;
//  `expireUnstartedAnnouncements()` models the real announcer's start bound
//  running out for a phrase the synthesizer never started.
//

import Foundation

@MainActor
final class FakeSpokenStateAnnouncer: SpokenStateAnnouncing {
    enum Event: Equatable {
        case announce(SpokenPhrase)
        case startRepeating(SpokenPhrase)
        case stopRepeating
        case cutOff
        case stopNow
    }

    /// Every call, in order.
    private(set) var events: [Event] = []
    /// Every one-shot `announce(_:)` phrase, in order.
    private(set) var announced: [SpokenPhrase] = []
    /// Every `startRepeating(_:)` phrase, in order.
    private(set) var startedRepeating: [SpokenPhrase] = []
    /// The phrase currently repeating, if any.
    private(set) var repeatingPhrase: SpokenPhrase?
    private(set) var stopRepeatingCount = 0
    private(set) var stopNowCount = 0
    private(set) var cutOffCount = 0
    private var pendingCompletions: [(hasStarted: Bool, completion: @MainActor () -> Void)] = []
    /// How many announced phrases have a completion still to run.
    var unfinishedAnnouncementCount: Int { pendingCompletions.count }

    func announce(_ phrase: SpokenPhrase, completion: (@MainActor () -> Void)?) {
        events.append(.announce(phrase))
        announced.append(phrase)
        if let completion { pendingCompletions.append((false, completion)) }
    }

    /// Every phrase announced so far has finished playing: run their completions,
    /// in the order the phrases were announced.
    func finishAnnouncements() {
        let completions = pendingCompletions
        pendingCompletions = []
        completions.forEach { $0.completion() }
    }

    /// The oldest phrase still playing has finished: run its completion only.
    func finishOldestAnnouncement() {
        guard !pendingCompletions.isEmpty else { return }
        pendingCompletions.removeFirst().completion()
    }

    /// The synthesizer started every phrase requested so far.
    func startAnnouncements() {
        pendingCompletions = pendingCompletions.map { (true, $0.completion) }
    }

    /// The start bound ran out for a phrase never started: as the real announcer
    /// does, everything still pending is cut off and its completions run.
    func expireUnstartedAnnouncements() {
        guard pendingCompletions.contains(where: { !$0.hasStarted }) else { return }
        finishAnnouncements()
    }

    func startRepeating(_ phrase: SpokenPhrase) {
        events.append(.startRepeating(phrase))
        startedRepeating.append(phrase)
        repeatingPhrase = phrase
    }

    func stopRepeating() {
        events.append(.stopRepeating)
        repeatingPhrase = nil
        stopRepeatingCount += 1
    }

    func cutOffPending() {
        events.append(.cutOff)
        cutOffCount += 1
        finishAnnouncements()
    }

    func stopNow() {
        events.append(.stopNow)
        repeatingPhrase = nil
        stopNowCount += 1
        finishAnnouncements() // cut off, as the real one does
    }
}
