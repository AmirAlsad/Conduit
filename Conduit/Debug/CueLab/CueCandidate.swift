//
//  CueCandidate.swift
//  Conduit
//
//  The playback mechanisms the Cue Lab compares. The raw value is the stable
//  suffix of the button's accessibility identifier.
//

#if DEBUG
import Foundation

enum CueCandidate: String, CaseIterable, Identifiable {
    case synthAppSession = "1"
    case synthOwnSession = "2"
    case synthFilePlayer = "3"
    case synthEngine = "4"
    case ringPlayer = "5"
    case ringSystemSound = "6a"
    case ringAlertSound = "6b"
    case liveKitSpeech = "7a"
    case liveKitRing = "7b"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .synthAppSession: "1 Synth (app session)"
        case .synthOwnSession: "2 Synth (own session)"
        case .synthFilePlayer: "3 Synth file (AVAudioPlayer)"
        case .synthEngine: "4 Synth buffer (AVAudioEngine)"
        case .ringPlayer: "5 Ring (AVAudioPlayer)"
        case .ringSystemSound: "6a Ring (system sound)"
        case .ringAlertSound: "6b Ring (alert sound)"
        case .liveKitSpeech: "7a LiveKit SoundPlayer speech"
        case .liveKitRing: "7b LiveKit SoundPlayer ring"
        }
    }

    var requiresLiveKit: Bool {
        self == .liveKitSpeech || self == .liveKitRing
    }
}
#endif
