//
//  DebugInterruptionRecovery.swift
//  Conduit
//
//  DEBUG-only choice of the package's experimental recoveries after a real phone
//  call interrupts a call (SPI `InterruptionRecoveryExperiment`), one per layer:
//  the audio session (E-A, E-B), LiveKit (L-A, L-B, L-C) and Daily (A, B, C). Kept in
//  UserDefaults so a VoIP push's cold launch uses it; the session's is read by the
//  engine when it needs it, each transport's when the transport is made. Release
//  builds compile none of this, so they never reference the SPI.
//

#if DEBUG
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngine
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngineDaily
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngineLiveKit
import Foundation

enum DebugInterruptionRecovery {
    static let sessionKey = "debug.interruptionRecovery.session"
    static let liveKitKey = "debug.interruptionRecovery.livekit"
    static let dailyKey = "debug.interruptionRecovery.daily"

    static func session(in defaults: UserDefaults = .standard) -> SessionInterruptionRecovery {
        defaults.string(forKey: sessionKey).flatMap(SessionInterruptionRecovery.init(rawValue:)) ?? .off
    }

    static func liveKit(in defaults: UserDefaults = .standard) -> LiveKitInterruptionRecovery {
        defaults.string(forKey: liveKitKey).flatMap(LiveKitInterruptionRecovery.init(rawValue:)) ?? .off
    }

    static func daily(in defaults: UserDefaults = .standard) -> DailyInterruptionRecovery {
        defaults.string(forKey: dailyKey).flatMap(DailyInterruptionRecovery.init(rawValue:)) ?? .off
    }

    /// The three choices, as the trace records them.
    static func summary(in defaults: UserDefaults = .standard) -> String {
        "session \(session(in: defaults).rawValue), livekit \(liveKit(in: defaults).rawValue), daily \(daily(in: defaults).rawValue)"
    }

    /// Lets the engine read the session's choice each time it needs it.
    @MainActor
    static func install(on engine: CallEngine) {
        engine.sessionInterruptionRecovery = { session() }
    }

    @MainActor
    static func makeDailyTransport() -> CallTransport {
        PipecatDailyTransport(interruptionRecovery: daily())
    }

    @MainActor
    static func makeLiveKitTransport() -> CallTransport {
        LiveKitTransport(interruptionRecovery: liveKit())
    }
}
#endif
