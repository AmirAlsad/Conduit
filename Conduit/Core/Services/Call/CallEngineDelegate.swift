//
//  CallEngineDelegate.swift
//  Conduit
//
//  The host's side of the call engine: it resolves incoming targets, observes
//  state transitions (spoken cues, Siri donation), records finished calls, and
//  supplies the bearer for ring-status receipts. Every call is synchronous and on
//  the main actor, in the order the engine makes the change, so a host sees each
//  transition in the same turn as the state assignment.
//

import Foundation

@MainActor
protocol CallEngineDelegate: AnyObject {
    /// Once per ringing push, after CallKit accepted the report (so never before the
    /// call rings). nil means the target is unknown and the ring fails.
    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget?
    /// Only on real assignments, after the engine's own field batch for that transition.
    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState)
    func callEngine(_ engine: CallEngine, didFinish record: CallRecord)
    /// Asked at send time, only when the push carried a `status_url`.
    func callEngine(_ engine: CallEngine, ringStatusBearerForTarget id: UUID) -> String?
    func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data)
}

extension CallEngineDelegate {
    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? { nil }
    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState) {}
    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {}
    func callEngine(_ engine: CallEngine, ringStatusBearerForTarget id: UUID) -> String? { nil }
    func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data) {}
}
