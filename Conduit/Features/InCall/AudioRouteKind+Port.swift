//
//  AudioRouteKind+Port.swift
//  Conduit
//
//  Maps a live `AVAudioSession` output port to an `AudioRouteKind`, so the in-call
//  picker can mark the route that's ACTUALLY active (the source of truth) rather
//  than trust the transport's "preferred device", which it doesn't report until
//  the user explicitly picks one.
//

import AVFoundation

extension AudioRouteKind {
    init(portType: AVAudioSession.Port) {
        switch portType {
        case .builtInSpeaker:
            self = .speaker
        case .builtInReceiver:
            self = .receiver
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .carAudio:
            self = .bluetooth
        case .headphones, .headsetMic, .usbAudio:
            self = .wired
        default:
            self = .other
        }
    }

    /// The kind of the current active output route.
    static var active: AudioRouteKind {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return .other
        }
        return AudioRouteKind(portType: port.portType)
    }
}
