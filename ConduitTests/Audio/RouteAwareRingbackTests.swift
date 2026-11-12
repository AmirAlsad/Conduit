//
//  RouteAwareRingbackTests.swift
//  ConduitTests
//
//  The route-aware ringback with the system sound, the player, the activation and
//  the route replaced: a ring chooses its method from the route only once CallKit
//  has activated the session (a ring stopped first never plays), keeps that method
//  through route changes, deactivations and reactivations, and a stop reaches the
//  method that played. A placed call's player is made at once and readied only in
//  an activated session on a headset-type route.
//

import AVFoundation
import Testing
@testable import Conduit

@MainActor
private final class RecordingRingback: RingbackPlaying {
    private(set) var calls: [String] = []
    func prepare() { calls.append("prepare") }
    func start() { calls.append("start") }
    func stop() { calls.append("stop") }
}

@MainActor
struct RouteAwareRingbackTests {
    private final class Session {
        var isActivated = false
        var outputs: [AVAudioSession.Port] = [.builtInReceiver]
    }

    private let session = Session()
    private let systemSound = RecordingRingback()
    private let players = FakeRingbackAudioPlayers()
    private let lines = Lines()

    private final class Lines {
        var all: [String] = []
    }

    private func ringback() -> RouteAwareRingback {
        let session = session
        let lines = lines
        let ringback = RouteAwareRingback(
            systemSound: systemSound,
            audioPlayer: players.ringback(),
            isAudioActivated: { session.isActivated },
            routeOutputs: { session.outputs }
        )
        ringback.trace = { lines.all.append($0) }
        return ringback
    }

    private func activate(_ ringback: RouteAwareRingback, outputs: [AVAudioSession.Port]? = nil) {
        if let outputs { session.outputs = outputs }
        session.isActivated = true
        ringback.audioActivationDidChange()
    }

    private func deactivate(_ ringback: RouteAwareRingback) {
        session.isActivated = false
        ringback.audioActivationDidChange()
    }

    private var playerPlays: Int { players.made.reduce(0) { $0 + $1.plays } }

    // MARK: - The choice

    @Test func anActivatedEarpieceRingPlaysTheSystemSound() {
        session.isActivated = true
        let ringback = ringback()
        ringback.prepare()
        ringback.start()

        #expect(systemSound.calls == ["start"])
        #expect(playerPlays == 0)
    }

    @Test(arguments: [AVAudioSession.Port.bluetoothHFP, .headphones, .carAudio])
    func anActivatedHeadsetRingPlaysTheAudioPlayer(output: AVAudioSession.Port) {
        session.isActivated = true
        session.outputs = [output]
        let ringback = ringback()
        ringback.prepare()
        ringback.start()

        #expect(systemSound.calls.isEmpty)
        #expect(playerPlays == 1)
    }

    @Test func aRingBeforeTheActivationPlaysNothingAndChoosesByTheRouteAtTheActivation() {
        let ringback = ringback()
        ringback.prepare()
        ringback.start() // the route still reads the earpiece
        #expect(systemSound.calls.isEmpty)
        #expect(playerPlays == 0)

        activate(ringback, outputs: [.bluetoothHFP])

        #expect(systemSound.calls.isEmpty)
        #expect(playerPlays == 1)
        #expect(lines.all.contains("ringback: waiting for CallKit's audio activation to choose a method"))
    }

    @Test func anUnknownOutputPlaysTheSystemSound() {
        session.isActivated = true
        session.outputs = [AVAudioSession.Port(rawValue: "SomeFutureOutput")]
        let ringback = ringback()
        ringback.start()

        #expect(systemSound.calls == ["start"])
        #expect(playerPlays == 0)
    }

    // MARK: - Start, stop and cancel

    @Test func aRingStoppedBeforeTheActivationNeverPlays() {
        let ringback = ringback()
        ringback.prepare()
        ringback.start()
        ringback.stop()

        activate(ringback, outputs: [.bluetoothHFP])
        activate(ringback, outputs: [.builtInReceiver])

        #expect(systemSound.calls.isEmpty)
        #expect(playerPlays == 0)
        #expect(lines.all.contains("ringback: stopped before it played"))
    }

    @Test func aStopSilencesTheMethodThatPlayed() {
        session.isActivated = true
        let ringback = ringback()
        ringback.start()

        ringback.stop()

        #expect(systemSound.calls == ["start", "stop"])
        #expect(lines.all.last == "ringback: stopped, method systemSound")
    }

    @Test func aStopSilencesThePlayerThatPlayed() throws {
        session.isActivated = true
        session.outputs = [.bluetoothHFP]
        let ringback = ringback()
        ringback.start()

        ringback.stop()

        let player = try #require(players.made.first)
        #expect(player.stops >= 1)
        #expect(systemSound.calls.isEmpty)
    }

    @Test func aSecondStartWhileRingingStartsNothing() {
        session.isActivated = true
        let ringback = ringback()
        ringback.start()
        ringback.start()
        ringback.audioActivationDidChange()

        #expect(systemSound.calls == ["start"])
    }

    @Test func aStopWithNothingRingingSilencesNothing() {
        let ringback = ringback()
        ringback.stop()

        #expect(systemSound.calls.isEmpty)
        #expect(lines.all.isEmpty)
    }

    @Test func eachRingChoosesAfresh() {
        session.isActivated = true
        let ringback = ringback()
        ringback.start()
        ringback.stop()

        session.outputs = [.bluetoothHFP]
        ringback.start()

        #expect(systemSound.calls == ["start", "stop"])
        #expect(playerPlays == 1)
    }

    // MARK: - One method for the life of a ring

    @Test func aRouteChangeWhileRingingKeepsTheMethod() {
        session.isActivated = true
        let ringback = ringback()
        ringback.start()

        session.outputs = [.bluetoothHFP] // AirPods connect mid-ring
        ringback.audioActivationDidChange()
        ringback.stop()

        #expect(systemSound.calls == ["start", "stop"])
        #expect(playerPlays == 0)
    }

    @Test func aDeactivationSilencesTheRingAndTheNextActivationPlaysTheSameMethod() {
        session.isActivated = true
        let ringback = ringback()
        ringback.start()

        deactivate(ringback)
        #expect(systemSound.calls == ["start", "stop"])

        activate(ringback, outputs: [.bluetoothHFP])
        #expect(systemSound.calls == ["start", "stop", "start"])
        #expect(playerPlays == 0)
    }

    @Test func aDeactivationSilencesThePlayerAndTheNextActivationPlaysItAgain() throws {
        session.isActivated = true
        session.outputs = [.bluetoothHFP]
        let ringback = ringback()
        ringback.start()

        deactivate(ringback)
        let first = try #require(players.made.first)
        #expect(first.stops == 1)

        activate(ringback, outputs: [.builtInReceiver])
        #expect(playerPlays == 2)
        #expect(systemSound.calls.isEmpty)
    }

    // MARK: - The player made and readied ahead

    @Test func placingACallMakesThePlayerButNeitherReadiesNorPlaysIt() throws {
        session.outputs = [.bluetoothHFP]
        ringback().prepare()

        let player = try #require(players.made.first)
        #expect(player.prepares == 0)
        #expect(player.plays == 0)
    }

    @Test func theActivationReadiesThePlayerOnAHeadsetRouteAndTheRingPlaysIt() throws {
        let ringback = ringback()
        ringback.prepare()

        activate(ringback, outputs: [.bluetoothHFP])
        let player = try #require(players.made.first)
        #expect(player.prepares == 1)
        #expect(player.plays == 0)

        ringback.start()
        #expect(players.made.count == 1)
        #expect(player.plays == 1)
    }

    @Test func theActivationLeavesThePlayerUnreadiedOnTheEarpiece() throws {
        let ringback = ringback()
        ringback.prepare()

        activate(ringback, outputs: [.builtInReceiver])

        let player = try #require(players.made.first)
        #expect(player.prepares == 0)
    }

    @Test func anActivationWithNoCallPlacedReadiesNothing() {
        let ringback = ringback()
        activate(ringback, outputs: [.bluetoothHFP])

        #expect(players.made.isEmpty)
    }

    @Test func aStopLetsGoOfThePlayerMadeAheadWhenTheSystemSoundRang() throws {
        session.isActivated = true
        session.outputs = [.bluetoothHFP]
        let ringback = ringback()
        ringback.prepare() // readied on the headset route
        session.outputs = [.builtInReceiver] // gone before the ring
        ringback.start()

        ringback.stop()

        let player = try #require(players.made.first)
        #expect(player.plays == 0)
        #expect(player.stops == 1)
        #expect(systemSound.calls == ["start", "stop"])
    }
}
