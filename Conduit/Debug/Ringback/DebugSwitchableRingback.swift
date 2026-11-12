//
//  DebugSwitchableRingback.swift
//  Conduit
//
//  DEBUG-only ringback that plays each ringing with the method chosen in Settings
//  (`DebugRingbackMethod`), read when the ringing starts, and stops the one it
//  started even if the choice changed meanwhile. Writes the method, the session's
//  output volume and route at the start, and the stop to the call trace.
//

#if DEBUG
import AVFoundation
import Foundation

@MainActor
final class DebugSwitchableRingback: RingbackPlaying {
    private let method: () -> DebugRingbackMethod
    private let systemSound: RingbackPlaying
    private let audioPlayer: RingbackPlaying
    private let describeSession: @MainActor () -> String
    private let trace: (String) -> Void
    private var ringing: (method: DebugRingbackMethod, ringback: RingbackPlaying)?

    init(
        method: @escaping () -> DebugRingbackMethod = { DebugRingbackMethod.current() },
        systemSound: RingbackPlaying,
        audioPlayer: RingbackPlaying,
        describeSession: @escaping @MainActor () -> String = DebugSwitchableRingback.describeSharedSession,
        trace: @escaping (String) -> Void
    ) {
        self.method = method
        self.systemSound = systemSound
        self.audioPlayer = audioPlayer
        self.describeSession = describeSession
        self.trace = trace
    }

    func start() {
        guard ringing == nil else { return }
        let method = method()
        let ringback = method == .audioPlayer ? audioPlayer : systemSound
        ringing = (method, ringback)
        trace("ringback: start, method \(method.rawValue); \(describeSession())")
        ringback.start()
    }

    func stop() {
        guard let ringing else { return }
        self.ringing = nil
        ringing.ringback.stop()
        trace("ringback: stop, method \(ringing.method.rawValue)")
    }

    /// The shared session's output volume and route, read without changing anything.
    static func describeSharedSession() -> String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue) \"\($0.portName)\"" }
        let route = outputs.isEmpty ? "no output" : outputs.joined(separator: ", ")
        return "session output volume \(session.outputVolume), route \(route), category \(session.category.rawValue), mode \(session.mode.rawValue)"
    }
}
#endif
