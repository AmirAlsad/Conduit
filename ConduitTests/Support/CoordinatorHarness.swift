//
//  CoordinatorHarness.swift
//  ConduitTests
//
//  Shared fixtures for CallSessionCoordinator tests: the four fakes, an in-memory
//  SwiftData repository with one inserted agent, and a controllable clock. The
//  coordinator depends only on protocols, so the whole state machine runs here at
//  simulator speed.
//

import Foundation
import SwiftData
import Testing
@testable import Conduit

/// A clock the tests advance by hand to make durations deterministic.
@MainActor
final class MutableClock {
    var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }
    func now() -> Date { current }
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

@MainActor
final class CoordinatorHarness {
    let provider = FakeCallProvider()
    let keychain = InMemoryKeychain()
    let announcer = FakeSpokenStateAnnouncer()
    let transport = FakeTransport()
    let container: ModelContainer
    let repository: SwiftDataAgentRepository
    let coordinator: CallSessionCoordinator
    let agent: Agent
    let callID = UUID()

    init(
        policy: ReconnectionPolicy = .default,
        token: String? = "valid-token",
        pushToTalk: Bool = false,
        now: @escaping () -> Date = { Date() }
    ) throws {
        container = try ModelContainer(
            for: Agent.self, CallLogEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        repository = SwiftDataAgentRepository(context: container.mainContext)

        provider.nextCallID = callID

        let agent = Agent(
            name: "Echo Bot",
            detail: "test parrot",
            transportKind: .daily,
            connectionURL: URL(string: "https://example.daily.co/room")!
        )
        self.agent = agent
        repository.insert(agent)
        try repository.save()

        // The harness agent is direct-mode (connectionURL), so its secret lives under
        // the direct-token ref the coordinator loads for that path.
        if let token {
            try keychain.setToken(token, for: KeychainTokenRef(directTokenForAgentID: agent.id))
        }

        let transport = self.transport
        coordinator = CallSessionCoordinator(
            callProvider: provider,
            transportFactory: { _ in transport },
            keychain: keychain,
            repository: repository,
            announcer: announcer,
            policy: policy,
            now: now,
            sleep: { _ in },
            isPushToTalkEnabled: { pushToTalk }
        )
    }

    func loggedEntries() throws -> [CallLogEntry] {
        try container.mainContext.fetch(FetchDescriptor<CallLogEntry>())
    }
}

/// Yield the main actor until `condition` holds or the tick budget runs out, so a
/// test can await an event delivered through an async path (e.g. the transport
/// event stream) without a brittle fixed sleep.
@MainActor
func waitUntil(ticks: Int = 500, _ condition: () -> Bool) async {
    for _ in 0..<ticks {
        if condition() { return }
        await Task.yield()
    }
}

extension CallState {
    /// Case-only matchers so tests can assert state without pinning the
    /// associated `Date` of `.connected`.
    var isConnected: Bool { if case .connected = self { return true } else { return false } }
    var isConnecting: Bool { if case .connecting = self { return true } else { return false } }
    var reconnectingAttempt: Int? {
        if case .reconnecting(let n) = self { return n } else { return nil }
    }
    var failureReason: CallFailureReason? {
        if case .failed(let r) = self { return r } else { return nil }
    }
    var endedOutcome: CallOutcome? {
        if case .ended(let o) = self { return o } else { return nil }
    }
}
