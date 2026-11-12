//
//  RouteAwareRingback.swift
//  Conduit
//
//  The ringback the app plays: each ring picks its method from the audio route
//  (`RingbackMethod`), the system sound on the phone's own outputs and the audio
//  player on a headset-type one.
//
//  The route is the call's only once CallKit has activated the session, so a ring
//  waits for the activation (`isAudioActivated`) before it chooses and plays; a ring
//  stopped first never plays. A deactivation silences it, and the next activation
//  of the same ring plays it again. The method chosen is kept for the whole ring,
//  even if the route changes meanwhile.
//
//  `prepare()` (the call was placed) makes the audio player ahead of the ring, and
//  once the session is activated on a headset-type route it is readied to play too,
//  so the ring's start does not wait for either. Nothing here activates, deactivates
//  or configures the session; the route is only read.
//

import AVFoundation
import Foundation
import Observation

@MainActor
final class RouteAwareRingback: RingbackPlaying {
    private let systemSound: RingbackPlaying
    private let audioPlayer: AudioPlayerRingback
    private let routeOutputs: @MainActor () -> [AVAudioSession.Port]
    private var isAudioActivated: @MainActor () -> Bool
    /// `prepare()` came, and no `stop()` since.
    private var isCallPlaced = false
    private var ring: Ring?
    #if DEBUG
    var trace: ((String) -> Void)?
    #endif

    private struct Ring {
        /// Chosen at the first activation of the ring, then kept.
        var method: RingbackMethod?
        var isPlaying = false
    }

    init(
        systemSound: RingbackPlaying,
        audioPlayer: AudioPlayerRingback,
        isAudioActivated: @escaping @MainActor () -> Bool = { false },
        routeOutputs: @escaping @MainActor () -> [AVAudioSession.Port] = RouteAwareRingback.sharedSessionOutputs
    ) {
        self.systemSound = systemSound
        self.audioPlayer = audioPlayer
        self.isAudioActivated = isAudioActivated
        self.routeOutputs = routeOutputs
    }

    /// Reads the call's audio activation from `read` (an observable value), and
    /// plays or silences a ring as it changes.
    func followAudioActivation(_ read: @escaping @MainActor () -> Bool) {
        isAudioActivated = read
        observeActivation()
    }

    func prepare() {
        isCallPlaced = true
        audioPlayer.prepare()
        prepareAudioPlayerIfItWillRing()
    }

    func start() {
        guard ring == nil else { return }
        ring = Ring()
        if isAudioActivated() {
            play()
        } else {
            trace("waiting for CallKit's audio activation to choose a method")
        }
    }

    func stop() {
        isCallPlaced = false
        if let ring {
            self.ring = nil
            if ring.isPlaying, let method = ring.method {
                ringback(for: method).stop()
                trace("stopped, method \(method.rawValue)")
            } else {
                trace("stopped before it played")
            }
        }
        // Lets go of a player made ahead for a ring that used the system sound or
        // never came.
        audioPlayer.stop()
    }

    /// The call's audio activation changed.
    func audioActivationDidChange() {
        if isAudioActivated() {
            if ring == nil {
                prepareAudioPlayerIfItWillRing()
            } else {
                play()
            }
        } else if var ring, ring.isPlaying, let method = ring.method {
            ringback(for: method).stop()
            ring.isPlaying = false
            self.ring = ring
            trace("silenced, the audio session was deactivated (method \(method.rawValue))")
        }
    }

    private func play() {
        guard var ring, !ring.isPlaying else { return }
        let method: RingbackMethod
        if let kept = ring.method {
            method = kept
            trace("playing again on the activation, method \(method.rawValue) kept")
        } else {
            let outputs = routeOutputs()
            method = RingbackMethod.forRoute(outputs: outputs)
            ring.method = method
            trace("chose \(method.rawValue): route \(Self.describe(outputs)) is \(method == .audioPlayer ? "a headset-type output (the call volume)" : "the phone's own or another output (the ringer volume)")")
        }
        ring.isPlaying = true
        self.ring = ring
        ringback(for: method).start()
    }

    /// Readies the audio player in an activated session for a placed call whose ring
    /// has not started, when the route is one it would ring on.
    private func prepareAudioPlayerIfItWillRing() {
        guard isCallPlaced, ring == nil, isAudioActivated() else { return }
        let outputs = routeOutputs()
        guard RingbackMethod.forRoute(outputs: outputs) == .audioPlayer else { return }
        trace("route \(Self.describe(outputs)) at the activation; readying the audio player")
        audioPlayer.prepareToPlay()
    }

    private func ringback(for method: RingbackMethod) -> RingbackPlaying {
        switch method {
        case .systemSound: systemSound
        case .audioPlayer: audioPlayer
        }
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

    /// The current route's output types, read without changing the session.
    static func sharedSessionOutputs() -> [AVAudioSession.Port] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
    }

    private static func describe(_ outputs: [AVAudioSession.Port]) -> String {
        outputs.isEmpty ? "(no output)" : outputs.map(\.rawValue).joined(separator: ", ")
    }

    private func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
        trace?("ringback: \(line())")
        #endif
    }
}
