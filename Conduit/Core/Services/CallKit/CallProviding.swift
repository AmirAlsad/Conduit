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

@MainActor
protocol CallProviding: AnyObject {
    var delegate: CallProviderDelegate? { get set }

    /// Report an outgoing call to the system. Returns the call's UUID.
    func startOutgoingCall(handle: CallHandle, displayName: String) async throws -> UUID
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
