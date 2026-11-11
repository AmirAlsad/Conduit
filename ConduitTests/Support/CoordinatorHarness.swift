//
//  CoordinatorHarness.swift
//  ConduitTests
//
//  Shared fixtures for CallSessionCoordinator tests: the fakes (including a
//  suspendable pairing resolver), an in-memory SwiftData repository with one
//  inserted agent, and a controllable clock. The
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

/// Stands in for `PairingClient.resolve`: records every request and can hold each
/// one open until `release()`, so a test can act while credentials are in flight.
@MainActor
final class FakePairingResolver {
    struct Request: Equatable {
        let endpoint: URL
        let apiKey: String
        let kind: TransportKind
    }

    private(set) var requests: [Request] = []
    var result: Result<PairingCredentials, any Error> = .success(
        PairingCredentials(roomURL: URL(string: "https://example.daily.co/paired")!, token: "paired-token")
    )
    var suspend = false
    private var pending: [CheckedContinuation<Void, Never>] = []

    func resolve(endpoint: URL, apiKey: String, kind: TransportKind) async throws -> PairingCredentials {
        requests.append(Request(endpoint: endpoint, apiKey: apiKey, kind: kind))
        if suspend {
            await withCheckedContinuation { pending.append($0) }
        }
        return try result.get()
    }

    /// Resume every suspended resolve; each then returns (or throws) `result`.
    func release() {
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume() }
    }
}

/// The transport kinds the coordinator asked its factory for, in order.
@MainActor
final class TransportRequestLog {
    var kinds: [TransportKind] = []
}

@MainActor
final class CoordinatorHarness {
    let provider = FakeCallProvider()
    let keychain = InMemoryKeychain()
    let announcer = FakeSpokenStateAnnouncer()
    let interruption = FakeAudioInterruptionObserver()
    let missedNotifier = FakeMissedCallNotifier()
    let ringStatusReporter = FakeRingStatusReporter()
    let interactionDonor = FakeCallInteractionDonor()
    let transport = FakeTransport()
    let pairing = FakePairingResolver()
    let transportRequests = TransportRequestLog()
    let container: ModelContainer
    let repository: SwiftDataAgentRepository
    let coordinator: CallSessionCoordinator
    let agent: Agent
    let callID = UUID()

    /// `pairingEndpoint` makes the agent pairing-mode: `token` is then its API key
    /// and every connect attempt goes through `pairing`.
    init(
        policy: ReconnectionPolicy = .default,
        token: String? = "valid-token",
        pairingEndpoint: URL? = nil,
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
            connectionURL: pairingEndpoint == nil ? URL(string: "https://example.daily.co/room")! : nil,
            pairingEndpoint: pairingEndpoint
        )
        self.agent = agent
        repository.insert(agent)
        try repository.save()

        // Each path's secret lives under the ref the coordinator loads for it: the
        // API key for a pairing agent, the room token for a direct one.
        if let token {
            let ref = pairingEndpoint != nil
                ? KeychainTokenRef(account: agent.keychainTokenRef)
                : KeychainTokenRef(directTokenForAgentID: agent.id)
            try keychain.setToken(token, for: ref)
        }

        let transport = self.transport
        let pairing = self.pairing
        let transportRequests = self.transportRequests
        coordinator = CallSessionCoordinator(
            callProvider: provider,
            transportFactory: { kind in
                transportRequests.kinds.append(kind)
                return transport
            },
            pairingResolver: { try await pairing.resolve(endpoint: $0, apiKey: $1, kind: $2) },
            keychain: keychain,
            repository: repository,
            announcer: announcer,
            interruptionObserver: interruption,
            missedCallNotifier: missedNotifier,
            ringStatusReporter: ringStatusReporter,
            interactionDonor: interactionDonor,
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
