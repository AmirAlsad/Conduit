//
//  DebugDailyRingJoin.swift
//  Conduit
//
//  DEBUG-only switch for the package's experimental Daily ring-join strategies
//  (`DailyRingJoinStrategy`, SPI), for the device test that decides whether, and
//  how, a Daily call may join while it rings. Persisted in UserDefaults so it
//  survives the cold launch a VoIP push causes; read each time a Daily transport
//  is made. A ring joins early only when its push asks for `preconnect: media`.
//  Release builds compile none of this, so they never reference the SPI.
//

#if DEBUG
@_spi(RingJoinExperiment) import ConduitCallEngineDaily
import ConduitCallEngine
import Foundation

enum DebugDailyRingJoin: String, CaseIterable, Identifiable {
    case off
    case d1 = "D1"
    case d2 = "D2"
    case d3 = "D3"

    static let defaultsKey = "debug.dailyRingJoinStrategy"

    static func current(in defaults: UserDefaults = .standard) -> DebugDailyRingJoin {
        defaults.string(forKey: defaultsKey).flatMap(DebugDailyRingJoin.init(rawValue:)) ?? .off
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off — join after the answer"
        case .d1: "D1 — default subscriptions"
        case .d2: "D2 — agent audio unsubscribed until answer"
        case .d3: "D3 — agent audio staged until answer"
        }
    }

    private var strategy: DailyRingJoinStrategy {
        switch self {
        case .off: .unsupported
        case .d1: .defaultSubscriptions
        case .d2: .agentAudioUnsubscribedUntilAnswer
        case .d3: .agentAudioStagedUntilAnswer
        }
    }

    /// A Daily transport with the chosen strategy; `.off` is the stock transport.
    @MainActor
    static func makeTransport() -> CallTransport {
        let choice = current()
        let transport = choice == .off
            ? PipecatDailyTransport()
            : PipecatDailyTransport(ringJoinStrategy: choice.strategy)
        CallTrace.record("""
        daily transport made: ring-join \(choice.rawValue) \
        (strategy \(choice.strategy.rawValue), canConnectWhileRinging=\(transport.canConnectWhileRinging))
        """)
        return transport
    }
}
#endif
