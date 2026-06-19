//
//  FakeTransport.swift
//  Conduit
//
//  In-app fake conforming to `Transport`. Lives in the app target (not the test
//  target) so the unit suite, SwiftUI previews, and the CallKit-free debug path
//  all share it. A test pushes events with `emit(_:)` and asserts the coordinator
//  reacts.
//

import Foundation

final class FakeTransport: Transport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var lastConfig: TransportConfig?
    private(set) var isMicEnabled = false
    private(set) var setMicEnabledCallCount = 0
    private(set) var isAudioAttached = false

    /// When set, the next `connect(_:)` throws this instead of succeeding.
    var connectError: TransportError?

    /// When true, `connect(_:)` suspends until `releaseConnect()` — lets a test fail
    /// and reset the call before `connect` resolves, exercising late-resolution races.
    var suspendConnect = false
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var connectReleased = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    func connect(_ config: TransportConfig) async throws {
        connectCount += 1
        lastConfig = config
        if suspendConnect {
            await withCheckedContinuation { cont in
                if connectReleased { cont.resume() } else { connectContinuation = cont }
            }
        }
        if let connectError { throw connectError }
    }

    /// Resume a `connect(_:)` suspended by `suspendConnect` (resolves on the next call
    /// if it hasn't suspended yet).
    func releaseConnect() {
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume()
        } else {
            connectReleased = true
        }
    }

    func disconnect() async {
        disconnectCount += 1
    }

    func setMicEnabled(_ enabled: Bool) async {
        isMicEnabled = enabled
        setMicEnabledCallCount += 1
    }

    var fakeAudioDevices: [AudioDeviceInfo] = [
        AudioDeviceInfo(id: "speaker", name: "Speaker"),
        AudioDeviceInfo(id: "receiver", name: "iPhone"),
    ]
    private(set) var selectedAudioDeviceID = "speaker"

    func availableAudioDevices() async -> [AudioDeviceInfo] { fakeAudioDevices }
    func selectedAudioDevice() async -> AudioDeviceInfo? {
        fakeAudioDevices.first { $0.id == selectedAudioDeviceID }
    }
    func setAudioDevice(_ id: String) async { selectedAudioDeviceID = id }

    func attachAudioSession() async {
        isAudioAttached = true
    }

    func detachAudioSession() async {
        isAudioAttached = false
    }

    /// Drive an event onto the stream from a test or the debug path.
    func emit(_ event: TransportEvent) {
        continuation.yield(event)
    }

    /// Close the event stream (mirrors a fully torn-down transport).
    func finish() {
        continuation.finish()
    }
}
