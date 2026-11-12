//
//  CueLabLog.swift
//  Conduit
//
//  Timestamped Cue Lab lines in the call trace file (`conduit-call-trace.log`),
//  plus the read-only AVAudioSession snapshots they carry. Nothing here sets
//  session state.
//

#if DEBUG
import AVFoundation
import Foundation

enum CueLabLog {
    static func record(_ line: String) {
        let stamp = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        CallTrace.record("\(stamp) CUELAB \(line)")
    }

    static func sessionSummary() -> String {
        let session = AVAudioSession.sharedInstance()
        return """
        category=\(session.category.rawValue) mode=\(session.mode.rawValue) \
        options=\(optionNames(session.categoryOptions)) \
        otherAudioPlaying=\(session.isOtherAudioPlaying) \
        silenceHint=\(session.secondaryAudioShouldBeSilencedHint) \
        sampleRate=\(session.sampleRate) outputVolume=\(session.outputVolume) \
        route=\(routeSummary(session.currentRoute))
        """
    }

    static func routeSummary(_ route: AVAudioSessionRouteDescription) -> String {
        "in=[\(portSummary(route.inputs))] out=[\(portSummary(route.outputs))]"
    }

    private static func portSummary(_ ports: [AVAudioSessionPortDescription]) -> String {
        ports.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
    }

    // Raw bit values keep this independent of the iOS 26 renames
    // (`allowBluetooth` became `allowBluetoothHFP`).
    private static let optionBits: [(UInt, String)] = [
        (0x1, "mixWithOthers"), (0x2, "duckOthers"), (0x4, "allowBluetoothHFP"),
        (0x8, "defaultToSpeaker"), (0x10, "interruptSpokenAudioAndMixWithOthers"),
        (0x20, "allowBluetoothA2DP"), (0x40, "allowAirPlay"),
        (0x80, "overrideMutedMicrophoneInterruption"),
    ]

    static func optionNames(_ options: AVAudioSession.CategoryOptions) -> String {
        let names = optionBits.filter { options.rawValue & $0.0 != 0 }.map(\.1)
        return "[\(names.joined(separator: ","))](raw \(options.rawValue))"
    }
}
#endif
