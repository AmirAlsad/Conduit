//
//  CallTraceObserver.swift
//  Conduit
//
//  DEBUG-only: writes the engine's observable call state that no delegate
//  callback reports into the call trace — the ring's pre-connect phase, hold,
//  CallKit audio activation (as the engine counts it: an activation it ignores,
//  such as one during an unanswered ring, does not show), interruption and mute.
//  Changes made in one main-actor turn are seen together, as their final values.
//

#if DEBUG
import ConduitCallEngine
import Observation

@MainActor
final class CallTraceObserver {
    private struct Snapshot: Equatable {
        var ringPreparation: RingPreparationPhase
        var isOnHold: Bool
        var isAudioActivated: Bool
        var isInterrupted: Bool
        var isMuted: Bool
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
                ringPreparation: engine.ringPreparationPhase,
                isOnHold: engine.isOnHold,
                isAudioActivated: engine.isAudioActivated,
                isInterrupted: engine.isInterrupted,
                isMuted: engine.isMuted
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
            engine: ringPreparation=\(new.ringPreparation) onHold=\(new.isOnHold) \
            audioActivated=\(new.isAudioActivated) interrupted=\(new.isInterrupted) muted=\(new.isMuted)
            """)
            return
        }
        if new.ringPreparation != last.ringPreparation {
            CallTrace.record("ring preparation: \(last.ringPreparation) -> \(new.ringPreparation)")
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
    }
}
#endif
