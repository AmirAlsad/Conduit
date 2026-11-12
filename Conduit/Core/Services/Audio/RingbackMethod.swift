//
//  RingbackMethod.swift
//  Conduit
//
//  How the ringback is played on a given audio route. Neither method works on every
//  route (device test, iPhone 17, iOS 27.0): the system sound plays at the ringer
//  volume, quiet but fine at the ear and far too loud in AirPods, while an
//  `AVAudioPlayer` in the app's session plays at the call volume, steady in AirPods
//  and inaudible on the earpiece even at full volume.
//

import AVFoundation

enum RingbackMethod: String {
    /// `SystemRingback`: the system-sound server, at the ringer volume.
    case systemSound
    /// `AudioPlayerRingback`: an `AVAudioPlayer` in the app's session, at the call volume.
    case audioPlayer

    /// The method for a route: its first output decides (a call's route has one),
    /// and a route with no output gets the system sound.
    static func forRoute(outputs: [AVAudioSession.Port]) -> RingbackMethod {
        outputs.first.map(forOutput) ?? .systemSound
    }

    static func forOutput(_ port: AVAudioSession.Port) -> RingbackMethod {
        switch port {
        // Headset-type outputs, worn or in the car: the system sound plays at the
        // ringer volume, far too loud there (AirPods, tested), while the player
        // follows the call volume (AirPods, tested).
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .carAudio, .usbAudio:
            return .audioPlayer
        // The phone's own outputs: the player was inaudible on the earpiece; the
        // system sound was heard on the earpiece and on the speaker.
        case .builtInReceiver, .builtInSpeaker:
            return .systemSound
        // Outputs a call is not expected to use, none tested: the system sound, as
        // for an unknown type below.
        case .lineOut, .HDMI, .airPlay, .displayPort, .thunderbolt, .fireWire, .PCI, .AVB, .virtual:
            return .systemSound
        // Input-only ports; never an output.
        case .builtInMic, .headsetMic, .lineIn, .continuityMicrophone:
            return .systemSound
        // A type not listed here (iOS 27's `mediaDeviceExtension`, or a later one):
        // the system sound has been heard on every route tried, whereas the player's
        // failure is a ring nobody hears.
        default:
            return .systemSound
        }
    }
}
