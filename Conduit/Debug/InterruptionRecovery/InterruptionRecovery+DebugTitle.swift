//
//  InterruptionRecovery+DebugTitle.swift
//  Conduit
//
//  Picker titles for the experimental recoveries after a phone call (DEBUG only).
//

#if DEBUG
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngine
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngineDaily
@_spi(InterruptionRecoveryExperiment) import ConduitCallEngineLiveKit

extension SessionInterruptionRecovery {
    var debugTitle: String {
        switch self {
        case .off: "Off"
        case .reapplyCategory: "E-A — set category and mode again"
        case .reapplyCategoryAndActivate: "E-B — E-A, then setActive(true)"
        }
    }
}

extension LiveKitInterruptionRecovery {
    var debugTitle: String {
        switch self {
        case .off: "Off"
        case .restartEngine: "L-A — engine off and on at once"
        case .restartEngineUntilRunning: "L-B — after a pause, until running"
        case .notifyActivationThenRestart: "L-C — tell WebRTC of the activation, then L-A"
        }
    }
}

extension DailyInterruptionRecovery {
    var debugTitle: String {
        switch self {
        case .off: "Off"
        case .restartMedia: "A — restart mic and agent audio"
        case .reassertAudioDevice: "B — re-assert the audio device"
        case .rejoin: "C — rejoin the room"
        }
    }
}
#endif
