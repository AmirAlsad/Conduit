//
//  FakeRingbackAudioPlayer.swift
//  ConduitTests
//
//  Stand-ins for the ringback's players: an `AVAudioPlayer` that records what it
//  was asked to do, and the factory that makes them for `AudioPlayerRingback`.
//

@testable import Conduit

final class FakeRingbackAudioPlayer: RingbackAudioPlayer {
    var volume: Float = 1
    var numberOfLoops = 0
    var playResult = true
    private(set) var prepares = 0
    private(set) var plays = 0
    private(set) var stops = 0

    func prepareToPlay() -> Bool {
        prepares += 1
        return true
    }

    func play() -> Bool {
        plays += 1
        return playResult
    }

    func stop() { stops += 1 }
}

/// Makes a fake player each time it is asked, keeping every one it made.
@MainActor
final class FakeRingbackAudioPlayers {
    private(set) var made: [FakeRingbackAudioPlayer] = []
    var playResult = true

    func make() -> RingbackAudioPlayer {
        let player = FakeRingbackAudioPlayer()
        player.playResult = playResult
        made.append(player)
        return player
    }

    func ringback() -> AudioPlayerRingback {
        AudioPlayerRingback(makePlayer: { self.make() })
    }
}
