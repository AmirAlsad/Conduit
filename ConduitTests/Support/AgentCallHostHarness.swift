//
//  AgentCallHostHarness.swift
//  ConduitTests
//
//  The host side driven by the real engine: an AgentCallHost over an in-memory
//  SwiftData repository with one agent, the Keychain, announcer, notifier, and
//  donor fakes, and a suspendable pairing resolver — wired as the delegate of a
//  CallEngine that runs against the CallKit and transport fakes.
//

import Foundation
import SwiftData
import Testing
@testable import Conduit
import ConduitCallEngine
import ConduitCallEngineTesting

/// Stands in for `PairingClient.resolve`: records every request and can hold each
/// one open until `release()`, so a test can act while credentials are in flight.
@MainActor
final class FakePairingResolver {
    struct Request: Equatable {
        let endpoint: URL
        let apiKey: String
        let kind: TransportKind
        var ring: PairingRing? = nil
    }

    private(set) var requests: [Request] = []
    var result: Result<PairingCredentials, any Error> = .success(
        PairingCredentials(roomURL: URL(string: "https://example.daily.co/paired")!, token: "paired-token")
    )
    var suspend = false
    private var pending: [CheckedContinuation<Void, Never>] = []

    func resolve(endpoint: URL, apiKey: String, kind: TransportKind, ring: PairingRing?) async throws -> PairingCredentials {
        requests.append(Request(endpoint: endpoint, apiKey: apiKey, kind: kind, ring: ring))
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

    var resolver: PairingResolving {
        { [self] in try await resolve(endpoint: $0, apiKey: $1, kind: $2, ring: $3) }
    }
}

/// Stands in for the host's delayed actions: records each wait and runs the
/// actions only when a test fires them, synchronously.
@MainActor
final class FakeDelays {
    private(set) var waits: [Duration] = []
    private var pending: [@MainActor () -> Void] = []

    var pendingCount: Int { pending.count }

    func schedule(_ wait: Duration, _ action: @escaping @MainActor () -> Void) {
        waits.append(wait)
        pending.append(action)
    }

    /// Every wait scheduled so far has passed: run their actions, oldest first.
    func fireAll() {
        let due = pending
        pending = []
        due.forEach { $0() }
    }
}

/// The transport kinds a factory was asked for, in order.
@MainActor
final class TransportRequestLog {
    var kinds: [TransportKind] = []
}

@MainActor
final class AgentCallHostHarness {
    let system = SimulatedCallSystem()
    let keychain = InMemoryKeychain()
    let announcer = FakeSpokenStateAnnouncer()
    let missedNotifier = FakeMissedCallNotifier()
    let interactionDonor = FakeCallInteractionDonor()
    let transports = FakeTransportPool()
    let pairing = FakePairingResolver()
    let transportRequests = TransportRequestLog()
    let delays = FakeDelays()
    let container: ModelContainer
    let repository: SwiftDataAgentRepository
    let host: AgentCallHost
    let engine: CallEngine
    let agent: Agent
    private(set) var pushCompletions = 0

    /// A real-time `sleep`, for a test that ends a timer with `fireTimer(_:)`; the
    /// default `sleep` runs every timer out at once.
    static let realTimeSleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// A `sleep` no timer outlasts by itself: every one ends only through
    /// `fireTimer(_:)` (or when the engine cancels it).
    static let parkedSleep: (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(24 * 60 * 60)) }

    /// `pairingEndpoint` makes the agent pairing-mode: `token` is then its API key
    /// and every connect attempt goes through `pairing`. The default `sleep` returns
    /// at once (instant reconnect backoff), so the ring timeout and the join deadline
    /// are off unless a test sets them, with a sleep it ends by hand.
    /// `configuration` replaces the harness's own, e.g. with the app's
    /// (`AppEnvironment.callEngineConfiguration()`); `ringTimeout` and `joinTimeout`
    /// then do not apply.
    init(
        token: String? = "valid-token",
        pairingEndpoint: URL? = nil,
        transportKind: TransportKind = .daily,
        now: @escaping () -> Date = { Date() },
        ringTimeout: Duration? = nil,
        joinTimeout: Duration? = nil,
        configuration: CallEngineConfiguration? = nil,
        sleep: @escaping (Duration) async throws -> Void = { _ in }
    ) throws {
        container = try ModelContainer(
            for: Agent.self, CallLogEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        repository = SwiftDataAgentRepository(context: container.mainContext)

        let agent = Agent(
            name: "Echo Bot",
            detail: "test parrot",
            transportKind: transportKind,
            connectionURL: pairingEndpoint == nil ? URL(string: "https://example.daily.co/room")! : nil,
            pairingEndpoint: pairingEndpoint
        )
        self.agent = agent
        repository.insert(agent)
        try repository.save()

        // Each path's secret lives under the ref the host loads for it: the API key
        // for a pairing agent, the room token for a direct one.
        if let token {
            let ref = pairingEndpoint != nil
                ? KeychainTokenRef(account: agent.keychainTokenRef)
                : KeychainTokenRef(directTokenForAgentID: agent.id)
            try keychain.setToken(token, for: ref)
        }

        let transports = self.transports
        let transportRequests = self.transportRequests
        let delays = self.delays
        host = AgentCallHost(
            repository: repository,
            keychain: keychain,
            announcer: announcer,
            missedCallNotifier: missedNotifier,
            interactionDonor: interactionDonor,
            transportFactory: { kind in
                transportRequests.kinds.append(kind)
                return transports.make()
            },
            pairingResolver: pairing.resolver,
            registrationSession: RecordingURLProtocol.session(),
            delay: { delays.schedule($0, $1) }
        )
        engine = CallEngine.simulated(
            configuration: configuration ?? CallEngineConfiguration(
                unknownCallerName: "Agent",
                ringTimeout: ringTimeout,
                joinTimeout: joinTimeout
            ),
            system: system,
            now: now,
            sleep: sleep
        )
        engine.delegate = host
        host.engine = engine
        engine.startPushRegistration()
    }

    /// The live call's transport (or the next call's, before it is placed).
    var transport: FakeTransport { transports.current }

    func placeCall() async {
        await engine.placeCall(host.target(for: agent))
    }

    func loggedEntries() throws -> [CallLogEntry] {
        try container.mainContext.fetch(FetchDescriptor<CallLogEntry>())
    }

    /// Deliver a VoIP push the way Conduit's reference engine sends one (keyed by
    /// `agent_id`), as PushKit would.
    func ring(
        agentID: UUID? = nil,
        callID: UUID = UUID(),
        displayName: String? = nil,
        handle: String? = nil,
        roomURL: URL? = nil,
        token: String? = nil,
        statusURL: URL? = nil,
        preconnect: String? = nil
    ) {
        var push: [AnyHashable: Any] = [
            "agent_id": (agentID ?? agent.id).uuidString,
            "call_id": callID.uuidString,
        ]
        push["display_name"] = displayName
        push["handle"] = handle
        push["room_url"] = roomURL?.absoluteString
        push["token"] = token
        push["status_url"] = statusURL?.absoluteString
        push["preconnect"] = preconnect
        system.deliverPush(push) { [self] in pushCompletions += 1 }
    }
}
