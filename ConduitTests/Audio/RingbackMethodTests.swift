//
//  RingbackMethodTests.swift
//  ConduitTests
//
//  The ringback's method per audio output: the audio player on headset-type
//  outputs, the system sound on the phone's own outputs and on every other type,
//  known or not; a route's first output decides.
//

import AVFoundation
import Testing
@testable import Conduit

struct RingbackMethodTests {
    @Test(arguments: [
        AVAudioSession.Port.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .carAudio, .usbAudio,
    ])
    func headsetTypeOutputsUseTheAudioPlayer(port: AVAudioSession.Port) {
        #expect(RingbackMethod.forOutput(port) == .audioPlayer)
    }

    @Test(arguments: [
        AVAudioSession.Port.builtInReceiver, .builtInSpeaker,
        .lineOut, .HDMI, .airPlay, .displayPort, .thunderbolt, .fireWire, .PCI, .AVB, .virtual,
        .builtInMic, .headsetMic, .lineIn, .continuityMicrophone,
        AVAudioSession.Port(rawValue: "SomeFutureOutput"),
    ])
    func everyOtherOutputUsesTheSystemSound(port: AVAudioSession.Port) {
        #expect(RingbackMethod.forOutput(port) == .systemSound)
    }

    @Test func aRouteWithNoOutputUsesTheSystemSound() {
        #expect(RingbackMethod.forRoute(outputs: []) == .systemSound)
    }

    @Test func aRoutesFirstOutputDecides() {
        #expect(RingbackMethod.forRoute(outputs: [.bluetoothHFP, .builtInSpeaker]) == .audioPlayer)
        #expect(RingbackMethod.forRoute(outputs: [.builtInReceiver, .bluetoothHFP]) == .systemSound)
    }
}
