//
//  UnavailableTransport.swift
//  Conduit
//
//  Placeholder for a transport kind that isn't wired yet (LiveKit lands in M6).
//  It fails fast on `connect`, so a call to such an agent surfaces a clean
//  "couldn't connect" instead of hanging in "Connecting…".
//

import Foundation

final class UnavailableTransport: Transport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let kind: TransportKind

    init(kind: TransportKind) {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
        self.kind = kind
    }

    func connect(_ config: TransportConfig) async throws {
        throw TransportError.connectionFailed("\(kind.displayName) transport is not available yet")
    }

    func disconnect() async { continuation.finish() }
    func setMicEnabled(_ enabled: Bool) async {}
    func attachAudioSession() async {}
    func detachAudioSession() async {}
}
