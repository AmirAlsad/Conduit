//
//  CallTarget.swift
//  Conduit
//
//  What the call engine is handed instead of a host model: who is being called
//  (identity for CallKit) and how to reach them. The engine creates the transport
//  once per call via `makeTransport`, BEFORE resolving credentials, so a CallKit
//  activation that lands mid-fetch reaches the transport; `connect` runs for the
//  first connect and again for every reconnect attempt.
//

import Foundation

struct CallTarget {
    let id: UUID
    let displayName: String
    /// The CallKit handle; nil falls back to `defaultHandle(for:)`.
    let handle: String?
    let makeTransport: @MainActor () -> any CallTransport
    let connect: @MainActor () async throws -> CallConnection

    static func defaultHandle(for id: UUID) -> String {
        "\(id.uuidString.lowercased())@calltarget.invalid"
    }
}

/// The live call, as the UI projects it.
struct ActiveCall: Equatable, Sendable {
    let targetID: UUID
    let displayName: String
    let direction: CallDirection
}

/// An incoming ring as the push described it, handed to the host to resolve.
struct IncomingCall: Equatable, Sendable {
    let callID: UUID
    let targetID: UUID
    let displayName: String
    let handle: String
    /// Inline room credentials from the push, when it carried both.
    let connection: CallConnection?
}
