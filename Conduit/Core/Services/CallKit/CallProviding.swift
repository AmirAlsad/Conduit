//
//  CallProviding.swift
//  Conduit
//
//  The app → system direction of the CallKit seam, abstracting `CXProvider` and
//  `CXCallController`. The real `SystemCallProvider` wraps CallKit; `FakeCallProvider`
//  lets the whole call state machine run in the simulator.
//
//  Reporting maps to CallKit lifecycle: `reportOutgoingCallConnecting` when the
//  transport begins connecting, `reportOutgoingCallConnected` only when media AND
//  bot are truly ready (this starts the native duration timer).
//

import Foundation

/// Thrown by `reportIncomingCall` when the system suppressed the ring (Focus/DND).
/// Not a failure: the caller logs a missed call instead of entering a failed state.
enum IncomingCallReportError: Error {
    case filteredByFocus
}

@MainActor
protocol CallProviding: AnyObject {
    var delegate: CallProviderDelegate? { get set }

    /// Report an outgoing call to the system. Returns the call's UUID.
    func startOutgoingCall(handle: CallHandle, displayName: String) async throws -> UUID
    /// Report an agent-initiated incoming call to the system (from a VoIP push). The
    /// `id` is the call's UUID (the push's call_id); the system then rings.
    func reportIncomingCall(id: UUID, handle: CallHandle, displayName: String) async throws
    func reportOutgoingCallConnecting(_ id: UUID)
    func reportOutgoingCallConnected(_ id: UUID)
    /// Request the system end the call (app-initiated End).
    func endCall(_ id: UUID) async
    /// Tell the system the call ended (transport-initiated / failure).
    func reportCallEnded(_ id: UUID, reason: CallEndReason)
    func setMuted(_ id: UUID, muted: Bool) async
    /// Hold/unhold — used to yield the audio route to a real incoming phone call (WS-3).
    func setOnHold(_ id: UUID, held: Bool) async
}
