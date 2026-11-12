//
//  AudioPlayerRingback.swift
//  Conduit
//
//  The ringback as `phone-ring.caf` looped by an `AVAudioPlayer` in the app's own
//  audio session, at a fixed moderate level, so it follows the call's volume and
//  route instead of the ringer's. `RouteAwareRingback` uses it on headset-type
//  routes (`RingbackMethod`).
//
//  CallKit owns the audio session: nothing here activates, deactivates or
//  configures it. An `AVAudioPlayer` that prepares or plays in an inactive session
//  activates that session itself, so `prepareToPlay()` and `start()` are only called
//  while CallKit has the session activated. `prepare()` only reads the file, which
//  touches no session, so it runs when the call is placed and the ring does not
//  wait for it.
//

import AVFoundation
import Foundation

/// The part of `AVAudioPlayer` the ringback uses, so a fake can stand in for it.
protocol RingbackAudioPlayer: AnyObject {
    var volume: Float { get set }
    var numberOfLoops: Int { get set }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func stop()
}

extension AVAudioPlayer: RingbackAudioPlayer {}

@MainActor
final class AudioPlayerRingback: RingbackPlaying {
    /// The player's own level, a fraction of the call's volume.
    static let volume: Float = 0.5

    private let makePlayer: @MainActor () -> RingbackAudioPlayer?
    private var player: RingbackAudioPlayer?
    private var isPreparedToPlay = false
    private var isPlaying = false
    #if DEBUG
    var trace: ((String) -> Void)?
    #endif

    init(makePlayer: @escaping @MainActor () -> RingbackAudioPlayer? = AudioPlayerRingback.makeBundledPlayer) {
        self.makePlayer = makePlayer
    }

    /// Makes the player from the file, if there is none yet.
    func prepare() {
        guard player == nil else { return }
        guard let player = timed({ makePlayer() }, { made, time in "player \(made == nil ? "not made" : "made") in \(time)" }) else {
            Log.error(.audio, "Ringback audio player could not be made")
            trace("no player (phone-ring.caf missing or unreadable)")
            return
        }
        player.numberOfLoops = -1
        player.volume = Self.volume
        self.player = player
    }

    /// Makes the player if need be and readies its buffers and output, so `start()`
    /// plays sooner. Only while CallKit has the session activated.
    func prepareToPlay() {
        prepare()
        guard let player, !isPreparedToPlay else { return }
        isPreparedToPlay = timed({ player.prepareToPlay() }, { prepared, time in "prepareToPlay() returned \(prepared) in \(time)" })
    }

    /// Plays on a loop. Only while CallKit has the session activated.
    func start() {
        guard !isPlaying else { return }
        prepare()
        guard let player else { return }
        let wasPreparedToPlay = isPreparedToPlay
        let played = timed({ player.play() }, { played, time in
            "play() returned \(played) in \(time)\(wasPreparedToPlay ? "" : " (not prepared ahead)"), player volume \(player.volume)"
        })
        guard played else {
            Log.warning(.audio, "Ringback audio player did not play")
            release()
            return
        }
        isPlaying = true
        Log.info(.audio, "Playing ringback (audio player) for call state: connecting")
    }

    /// Stops at once and lets the player go; the next ring makes a new one.
    func stop() {
        if isPlaying { trace("stopped") }
        release()
    }

    private func release() {
        player?.stop()
        player = nil
        isPreparedToPlay = false
        isPlaying = false
    }

    /// Runs `body`; in DEBUG, also traces its result and how long it took.
    private func timed<Result>(_ body: () -> Result, _ describe: (Result, String) -> String) -> Result {
        #if DEBUG
        let began = ContinuousClock.now
        let result = body()
        let elapsed = ContinuousClock.now - began
        trace(describe(result, "\(Int((elapsed / .milliseconds(1)).rounded())) ms"))
        return result
        #else
        return body()
        #endif
    }

    private func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
        trace?("ringback (audio player): \(line())")
        #endif
    }

    static func makeBundledPlayer() -> RingbackAudioPlayer? {
        guard let url = Bundle.main.url(forResource: "phone-ring", withExtension: "caf") else { return nil }
        do {
            return try AVAudioPlayer(contentsOf: url)
        } catch {
            Log.error(.audio, "Ringback audio player create failed: \(error)")
            return nil
        }
    }
}
