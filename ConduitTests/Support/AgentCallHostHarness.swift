//
//  AgentCallHostHarness.swift
//  ConduitTests
//
//  The host side driven by the real engine: an AgentCallHost over an in-memory
//  SwiftData repository with one agent, the Keychain, announcer, notifier, and
//  donor fakes, and a suspendable pairing resolver — wired as the delegate of a
//  CallSessionCoordinator that runs against the CallKit and transport fakes.
//

import Foundation
import SwiftData
import Testing
@testable import Conduit

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

    var resolver: PairingResolving {
        { [self] in try await resolve(endpoint: $0, apiKey: $1, kind: $2) }
    }
}

/// The transport kinds a factory was asked for, in order.
@MainActor
final class TransportRequestLog {
    var kinds: [TransportKind] = []
}

@MainActor
final class AgentCallHostHarness {
    let provider = FakeCallProvider()
    let interruption = FakeAudioInterruptionObserver()
    let ringStatusReporter = FakeRingStatusReporter()
    let keychain = InMemoryKeychain()
    let announcer = FakeSpokenStateAnnouncer()
    let missedNotifier = FakeMissedCallNotifier()
    let interactionDonor = FakeCallInteractionDonor()
    let transports = FakeTransportPool()
    let pairing = FakePairingResolver()
    let transportRequests = TransportRequestLog()
    let container: ModelContainer
    let repository: SwiftDataAgentRepository
    let host: AgentCallHost
    let coordinator: CallSessionCoordinator
    let agent: Agent
    let callID = UUID()
    private(set) var pushCompletions = 0

    /// `pairingEndpoint` makes the agent pairing-mode: `token` is then its API key
    /// and every connect attempt goes through `pairing`.
    init(
        policy: ReconnectionPolicy = .default,
        token: String? = "valid-token",
        pairingEndpoint: URL? = nil,
        transportKind: TransportKind = .daily,
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
            pairingResolver: pairing.resolver
        )
        coordinator = CallSessionCoordinator(
            callProvider: provider,
            interruptionObserver: interruption,
            ringStatusReporter: ringStatusReporter,
            policy: policy,
            now: now,
            sleep: { _ in },
            isPushToTalkEnabled: { false },
            unknownCallerName: "Agent"
        )
        coordinator.delegate = host
    }

    /// The live call's transport (or the next call's, before it is placed).
    var transport: FakeTransport { transports.current }

    func placeCall() async {
        await coordinator.placeCall(host.target(for: agent))
    }

    func loggedEntries() throws -> [CallLogEntry] {
        try container.mainContext.fetch(FetchDescriptor<CallLogEntry>())
    }

    /// Deliver a VoIP push the way Conduit's reference engine sends one (keyed by
    /// `agent_id`), through the coordinator's PushKit entry.
    func ring(
        agentID: UUID? = nil,
        callID: UUID = UUID(),
        displayName: String? = nil,
        handle: String? = nil,
        roomURL: URL? = nil,
        token: String? = nil,
        statusURL: URL? = nil
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
        coordinator.handleIncomingPush(push) { [self] in pushCompletions += 1 }
    }
}
