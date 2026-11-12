//
//  HostTestSupport.swift
//  ConduitTests
//
//  Small helpers the host-side call tests share: a hand-advanced clock, a
//  tick-bounded wait, a hand-fired sleep, a source of fresh fake transports, and
//  date-free `CallState` matchers.
//

import ConduitCallEngine
import ConduitCallEngineTesting
import Foundation

/// A clock the tests advance by hand to make durations deterministic.
@MainActor
final class MutableClock {
    var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }
    func now() -> Date { current }
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

/// Yield the main actor until `condition` holds or the tick budget runs out, so a
/// test can await an event delivered through an async path without a fixed sleep.
@MainActor
func waitUntil(ticks: Int = 500, _ condition: () -> Bool) async {
    for _ in 0..<ticks {
        if condition() { return }
        await Task.yield()
    }
}

/// Hands each call its own FakeTransport. `current` is the live call's transport —
/// or, before the next call, the one it will get — so a test can configure it
/// ahead of time.
@MainActor
final class FakeTransportPool {
    private(set) var made: [FakeTransport] = []
    private var next = FakeTransport()

    var current: FakeTransport { made.last ?? next }

    func make() -> FakeTransport {
        let transport = next
        made.append(transport)
        next = FakeTransport()
        return transport
    }
}

/// A `sleep` for the engine that returns only when the test says so, so a ring
/// timeout fires at a moment the test picks. Every sleeper is resumed by `fireAll()`.
@MainActor
final class ManualSleeper {
    private var pending: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int { pending.count }

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { pending.append($0) }
    }

    func fireAll() {
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume() }
    }
}

extension ConnectRequest {
    static let outgoing = ConnectRequest(purpose: .outgoing, callID: nil)
}

extension CallState {
    var isConnecting: Bool { if case .connecting = self { return true } else { return false } }
    var failureReason: CallFailureReason? {
        if case .failed(let r) = self { return r } else { return nil }
    }
    var endedOutcome: CallOutcome? {
        if case .ended(let o) = self { return o } else { return nil }
    }
}
