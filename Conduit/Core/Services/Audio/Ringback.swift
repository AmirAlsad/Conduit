//
//  Ringback.swift
//  Conduit
//
//  The phone ringback the announcer plays while a call the user placed connects,
//  and its timing, which the call engine's outgoing minimum connecting time is set
//  from. An answered call gets no ringback.
//
//  The app plays it with `RouteAwareRingback`, which picks per ring between the
//  system-sound server (`SystemRingback`, below) and an `AVAudioPlayer` in the
//  app's session (`AudioPlayerRingback`) by the audio route. No `AVAudioSession` is
//  activated, deactivated or configured (CallKit owns it).
//

import AudioToolbox
import Foundation

enum Ringback {
    /// How long after the connecting cue the ringback starts, so it does not start
    /// while the in-call screen is still sliding up. A call that ends sooner never rings.
    static let startDelay: Duration = .milliseconds(500)
    /// The audible part of one `phone-ring.caf` cycle.
    static let toneLength: Duration = .milliseconds(2100)
    /// How long the engine keeps a call the user placed connecting at least
    /// (`CallEngineConfiguration.minimumOutgoingConnectingDuration`), so the first
    /// tone plays in full before the call is reported connected and "Connected" is
    /// spoken.
    static let minimumOutgoingConnectingDuration = startDelay + toneLength
}

/// Plays the ringback on a loop until stopped.
@MainActor
protocol RingbackPlaying: AnyObject {
    /// The call was placed and a ring may follow: get ready without touching the
    /// audio session. A `stop()` undoes it.
    func prepare()
    func start()
    /// Stop at once, mid-tone if need be. Does nothing when not ringing.
    func stop()
}

/// The ringback as a looped system sound, at the ringer volume, whatever the route.
@MainActor
final class SystemRingback: RingbackPlaying {
    private var soundID: SystemSoundID = 0
    private var isRinging = false
    #if DEBUG
    var trace: ((String) -> Void)?
    #endif

    func prepare() {}

    func start() {
        guard soundID == 0 else { return }
        guard let url = Bundle.main.url(forResource: "phone-ring", withExtension: "caf") else {
            Log.error(.audio, "phone-ring.caf missing from bundle")
            return
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
        guard status == noErr else {
            Log.error(.audio, "Ringback system sound create failed: \(status)")
            trace("ringback (system sound): create failed, status \(status)")
            return
        }
        soundID = id
        isRinging = true
        playCycle()
        trace("ringback (system sound): playing at the ringer volume")
        Log.info(.audio, "Playing ringback for call state: connecting")
    }

    func stop() {
        isRinging = false
        guard soundID != 0 else { return }
        // Disposing halts an in-flight play immediately, so the tone never overlaps
        // the spoken "Connected" cue.
        AudioServicesDisposeSystemSoundID(soundID)
        soundID = 0
    }

    private func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
        trace?(line())
        #endif
    }

    /// Loop the ring by replaying each time the cycle finishes, until stopped.
    private func playCycle() {
        guard isRinging, soundID != 0 else { return }
        AudioServicesPlaySystemSoundWithCompletion(soundID) { [weak self] in
            Task { @MainActor in self?.playCycle() }
        }
    }
}
