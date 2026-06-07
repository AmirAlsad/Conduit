//
//  Transport.swift
//  Conduit
//
//  The seam over the Pipecat iOS client. Concrete adapters (DailyTransport,
//  later LiveKitTransport) live in this folder and conform here; nothing outside
//  references an SDK type. The call coordinator drives a `Transport` and consumes
//  its `events`.
//
//  AUDIO-SESSION INVARIANT: a transport must NOT seize the microphone or activate
//  the audio session on its own. Media attaches only when the coordinator calls
//  `attachAudioSession()`, which it does solely from CallKit's `providerDidActivate`.
//  CallKit owns the session; the transport attaches to it.
//

import Foundation

protocol Transport: AnyObject {
    /// The single channel by which transport state leaves the adapter.
    var events: AsyncStream<TransportEvent> { get }

    func connect(_ config: TransportConfig) async throws
    func disconnect() async
    func setMicEnabled(_ enabled: Bool) async

    /// Start media on the CallKit-activated session. Called ONLY from the
    /// coordinator's `providerDidActivate` handling.
    func attachAudioSession() async
    /// Stop media when CallKit deactivates the session or the call ends.
    func detachAudioSession() async
}
