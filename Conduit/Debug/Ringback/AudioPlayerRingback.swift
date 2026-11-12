//
//  AudioPlayerRingback.swift
//  Conduit
//
//  The ringback as `phone-ring.caf` looped by an `AVAudioPlayer` in the app's own
//  audio session, at a fixed moderate level, so it follows the call's volume and
//  route instead of the ringer's. DEBUG-only while a device test compares it with
//  `SystemRingback` (Settings > Debug > Ringback).
//
//  CallKit owns the audio session: nothing here activates, deactivates or
//  configures it. An `AVAudioPlayer` that starts playing in an inactive session
//  activates that session itself, so the player is made and played only while
//  CallKit has the session activated (`isAudioActivated`). The connecting cue can
//  come before the activation, so a start before it waits for it, and a ringback
//  stopped first never plays. A deactivation silences the player; the next
//  activation of the same ringing plays it again. A `play()` that returns false is
//  logged and not retried for that ringing.
//

#if DEBUG
import AVFoundation
import Foundation
import Observation

/// The part of `AVAudioPlayer` the ringback uses, so a fake can stand in for it.
protocol RingbackAudioPlayer: AnyObject {
    var volume: Float { get set }
    var numberOfLoops: Int { get set }
    func play() -> Bool
    func stop()
}

extension AVAudioPlayer: RingbackAudioPlayer {}

@MainActor
final class AudioPlayerRingback: RingbackPlaying {
    /// The player's own level, a fraction of the call's volume.
    static let volume: Float = 0.5

    private let makePlayer: @MainActor () -> RingbackAudioPlayer?
    private var isAudioActivated: @MainActor () -> Bool
    private var player: RingbackAudioPlayer?
    private var isRinging = false
    /// `play()` returned false during this ringing.
    private var playFailed = false
    var trace: ((String) -> Void)?

    init(
        isAudioActivated: @escaping @MainActor () -> Bool = { false },
        makePlayer: @escaping @MainActor () -> RingbackAudioPlayer? = AudioPlayerRingback.makeBundledPlayer
    ) {
        self.isAudioActivated = isAudioActivated
        self.makePlayer = makePlayer
    }

    /// Reads the call's audio activation from `read` (an observable value), and
    /// plays or silences a ringing as it changes.
    func followAudioActivation(_ read: @escaping @MainActor () -> Bool) {
        isAudioActivated = read
        observeActivation()
    }

    func start() {
        guard !isRinging else { return }
        isRinging = true
        playFailed = false
        if isAudioActivated() {
            play()
        } else {
            trace?("ringback (audio player): waiting for CallKit's audio activation")
        }
    }

    func stop() {
        guard isRinging else { return }
        isRinging = false
        let wasPlaying = player != nil
        player?.stop()
        player = nil
        trace?("ringback (audio player): stopped\(wasPlaying ? "" : " before it played")")
    }

    /// The call's audio activation changed: a ringing plays once the session is
    /// active and goes quiet when it is not.
    func audioActivationDidChange() {
        guard isRinging else { return }
        if isAudioActivated() {
            play()
        } else if let player {
            player.stop()
            self.player = nil
            trace?("ringback (audio player): silenced, the audio session was deactivated")
        }
    }

    private func play() {
        guard player == nil, !playFailed else { return }
        guard let player = makePlayer() else {
            playFailed = true
            Log.error(.audio, "Ringback audio player could not be made")
            trace?("ringback (audio player): no player (phone-ring.caf missing or unreadable)")
            return
        }
        player.numberOfLoops = -1
        player.volume = Self.volume
        let played = player.play()
        trace?("ringback (audio player): play() returned \(played), player volume \(player.volume)")
        guard played else {
            playFailed = true
            player.stop()
            Log.warning(.audio, "Ringback audio player did not play")
            return
        }
        self.player = player
        Log.info(.audio, "Playing ringback (audio player) for call state: connecting")
    }

    private func observeActivation() {
        _ = withObservationTracking {
            isAudioActivated()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeActivation()
                self?.audioActivationDidChange()
            }
        }
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
#endif
