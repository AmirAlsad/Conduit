//
//  CallTraceObserver.swift
//  Conduit
//
//  DEBUG-only: writes the engine's observable call state that no delegate
//  callback reports into the call trace — hold, CallKit audio activation (as the
//  engine counts it: an activation it ignores, such as one during an unanswered
//  ring, does not show; the raw activations are in the engine log lines),
//  interruption, mute and the host's mic withhold. Changes made in one main-actor
//  turn are seen together, as their final values. The ring's pre-connect phase is
//  not here: Observation loses its fast intermediate phases, so the call host
//  traces each change from the delegate callback.
//

#if DEBUG
import ConduitCallEngine
import Observation

@MainActor
final class CallTraceObserver {
    private struct Snapshot: Equatable {
        var isOnHold: Bool
        var isAudioActivated: Bool
        var isInterrupted: Bool
        var isMuted: Bool
        var isMicWithheld: Bool
    }

    private static var observers: [CallTraceObserver] = []

    private let engine: CallEngine
    private var last: Snapshot?

    private init(engine: CallEngine) {
        self.engine = engine
    }

    static func start(engine: CallEngine) {
        let observer = CallTraceObserver(engine: engine)
        observers.append(observer)
        observer.observe()
    }

    private func observe() {
        let snapshot = withObservationTracking {
            Snapshot(
                isOnHold: engine.isOnHold,
                isAudioActivated: engine.isAudioActivated,
                isInterrupted: engine.isInterrupted,
                isMuted: engine.isMuted,
                isMicWithheld: engine.isMicWithheld
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        record(snapshot)
    }

    private func record(_ new: Snapshot) {
        defer { last = new }
        guard let last else {
            CallTrace.record("""
            engine: onHold=\(new.isOnHold) \
            audioActivated=\(new.isAudioActivated) interrupted=\(new.isInterrupted) muted=\(new.isMuted) \
            micWithheld=\(new.isMicWithheld)
            """)
            return
        }
        if new.isOnHold != last.isOnHold {
            CallTrace.record(new.isOnHold ? "hold: on" : "hold: off")
        }
        if new.isAudioActivated != last.isAudioActivated {
            // Also cleared when a call ends, not only by a CallKit deactivation.
            CallTrace.record("audio activated: \(new.isAudioActivated)")
        }
        if new.isInterrupted != last.isInterrupted {
            CallTrace.record(new.isInterrupted ? "interruption: began" : "interruption: ended")
        }
        if new.isMuted != last.isMuted {
            CallTrace.record("muted: \(new.isMuted)")
        }
        if new.isMicWithheld != last.isMicWithheld {
            CallTrace.record("mic withheld: \(new.isMicWithheld)")
        }
    }
}
#endif
