//
//  AudioPlayerRingbackTests.swift
//  ConduitTests
//
//  The audio-player ringback with its player replaced: the player is made ahead by
//  `prepare()` and readied by `prepareToPlay()`, each once, and a start plays that
//  same player, looped at its fixed level; a stop silences it and lets it go, and a
//  `play()` that fails leaves nothing behind for the next start.
//

import Testing
@testable import Conduit

@MainActor
struct AudioPlayerRingbackTests {
    private let players = FakeRingbackAudioPlayers()

    @Test func aStartMakesAndPlaysALoopedPlayerAtItsLevel() throws {
        players.ringback().start()

        let player = try #require(players.made.first)
        #expect(players.made.count == 1)
        #expect(player.plays == 1)
        #expect(player.numberOfLoops == -1)
        #expect(player.volume == AudioPlayerRingback.volume)
    }

    @Test func prepareMakesThePlayerWithoutPreparingOrPlayingIt() throws {
        let ringback = players.ringback()
        ringback.prepare()
        ringback.prepare()

        let player = try #require(players.made.first)
        #expect(players.made.count == 1)
        #expect(player.prepares == 0)
        #expect(player.plays == 0)
    }

    @Test func aStartPlaysThePlayerMadeAndReadiedAhead() throws {
        let ringback = players.ringback()
        ringback.prepare()
        ringback.prepareToPlay()
        ringback.prepareToPlay()

        ringback.start()

        let player = try #require(players.made.first)
        #expect(players.made.count == 1)
        #expect(player.prepares == 1)
        #expect(player.plays == 1)
    }

    @Test func aSecondStartWhilePlayingPlaysNothingMore() {
        let ringback = players.ringback()
        ringback.start()
        ringback.start()

        #expect(players.made.count == 1)
        #expect(players.made.first?.plays == 1)
    }

    @Test func aStopSilencesThePlayerAndTheNextStartMakesANewOne() throws {
        let ringback = players.ringback()
        ringback.start()

        ringback.stop()
        let first = try #require(players.made.first)
        #expect(first.stops == 1)

        ringback.start()
        #expect(players.made.count == 2)
        #expect(players.made.last?.plays == 1)
    }

    @Test func aStopLetsGoOfAPlayerMadeAheadThatNeverPlayed() throws {
        let ringback = players.ringback()
        ringback.prepare()

        ringback.stop()
        ringback.start()

        let first = try #require(players.made.first)
        #expect(first.plays == 0)
        #expect(players.made.count == 2)
    }

    @Test func aFailedPlayLeavesNothingAndTheNextStartTriesAFreshPlayer() {
        players.playResult = false
        let ringback = players.ringback()
        ringback.start()
        #expect(players.made.first?.stops == 1)

        players.playResult = true
        ringback.start()
        #expect(players.made.count == 2)
        #expect(players.made.last?.plays == 1)
    }
}
