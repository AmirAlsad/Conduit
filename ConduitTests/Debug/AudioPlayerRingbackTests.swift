//
//  AudioPlayerRingbackTests.swift
//  ConduitTests
//
//  The audio-player ringback's ordering, with the player replaced: it plays only
//  while CallKit has the session activated (a start before the activation waits
//  for it, a stop before it means it never plays), loops at its fixed level, goes
//  quiet on a deactivation and plays again on the next activation, and a `play()`
//  that fails is not retried for that ringing.
//

import Testing
@testable import Conduit

private final class FakePlayer: RingbackAudioPlayer {
    var volume: Float = 1
    var numberOfLoops = 0
    var playResult = true
    private(set) var plays = 0
    private(set) var stops = 0

    func play() -> Bool {
        plays += 1
        return playResult
    }

    func stop() { stops += 1 }
}

@MainActor
struct AudioPlayerRingbackTests {
    private final class Activation {
        var isActivated = false
    }

    private final class Players {
        var made: [FakePlayer] = []
        var playResult = true
    }

    private let activation = Activation()
    private let players = Players()

    private func ringback() -> AudioPlayerRingback {
        let activation = activation
        let players = players
        return AudioPlayerRingback(
            isAudioActivated: { activation.isActivated },
            makePlayer: {
                let player = FakePlayer()
                player.playResult = players.playResult
                players.made.append(player)
                return player
            }
        )
    }

    @Test func playsAtOnceWhenTheSessionIsAlreadyActivated() throws {
        activation.isActivated = true
        ringback().start()

        let player = try #require(players.made.first)
        #expect(players.made.count == 1)
        #expect(player.plays == 1)
        #expect(player.numberOfLoops == -1)
        #expect(player.volume == AudioPlayerRingback.volume)
    }

    @Test func aStartBeforeTheActivationWaitsForIt() {
        let ringback = ringback()
        ringback.start()
        #expect(players.made.isEmpty)

        activation.isActivated = true
        ringback.audioActivationDidChange()

        #expect(players.made.count == 1)
        #expect(players.made.first?.plays == 1)
    }

    @Test func aStopBeforeTheActivationMeansItNeverPlays() {
        let ringback = ringback()
        ringback.start()
        ringback.stop()

        activation.isActivated = true
        ringback.audioActivationDidChange()

        #expect(players.made.isEmpty)
    }

    @Test func anActivationWithNothingRingingPlaysNothing() {
        let ringback = ringback()
        activation.isActivated = true
        ringback.audioActivationDidChange()

        #expect(players.made.isEmpty)
    }

    @Test func aStopSilencesThePlayerAtOnce() throws {
        activation.isActivated = true
        let ringback = ringback()
        ringback.start()

        ringback.stop()

        let player = try #require(players.made.first)
        #expect(player.stops == 1)
    }

    @Test func aSecondStartOrActivationWhilePlayingMakesNoSecondPlayer() {
        activation.isActivated = true
        let ringback = ringback()
        ringback.start()
        ringback.start()
        ringback.audioActivationDidChange()

        #expect(players.made.count == 1)
    }

    @Test func aDeactivationSilencesItAndTheNextActivationPlaysItAgain() throws {
        activation.isActivated = true
        let ringback = ringback()
        ringback.start()

        activation.isActivated = false
        ringback.audioActivationDidChange()
        let first = try #require(players.made.first)
        #expect(first.stops == 1)

        activation.isActivated = true
        ringback.audioActivationDidChange()
        #expect(players.made.count == 2)
        #expect(players.made.last?.plays == 1)
    }

    @Test func aFailedPlayIsNotRetriedForThatRinging() {
        players.playResult = false
        activation.isActivated = true
        let ringback = ringback()
        ringback.start()

        ringback.audioActivationDidChange()
        #expect(players.made.count == 1)

        players.playResult = true
        ringback.stop()
        ringback.start()
        #expect(players.made.count == 2) // a new ringing tries again
        #expect(players.made.last?.plays == 1)
    }
}
