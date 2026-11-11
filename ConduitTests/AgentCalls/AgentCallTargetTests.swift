//
//  AgentCallTargetTests.swift
//  ConduitTests
//
//  `Agent.callTarget(...)`: the identity CallKit sees, the adapter the agent's
//  kind selects, and the credential step — direct room + token, pairing (with
//  its error mapping), or inline push credentials — without the engine.
//

import Foundation
import Testing
@testable import Conduit

@MainActor
struct AgentCallTargetTests {

    private let endpoint = URL(string: "https://engine.example.com/connect/live")!
    private let room = URL(string: "https://example.daily.co/room")!

    private func directAgent(kind: TransportKind = .daily) -> Agent {
        Agent(name: "Echo Bot", detail: "", transportKind: kind, connectionURL: room)
    }

    private func pairingAgent() -> Agent {
        Agent(name: "Echo Bot", detail: "", transportKind: .livekit, pairingEndpoint: endpoint)
    }

    private func target(
        for agent: Agent,
        keychain: InMemoryKeychain? = nil,
        pairing: FakePairingResolver? = nil,
        inline: CallConnection? = nil,
        factory: @escaping (TransportKind) -> CallTransport = { _ in FakeTransport() }
    ) -> CallTarget {
        agent.callTarget(
            keychain: keychain ?? InMemoryKeychain(), transportFactory: factory,
            pairingResolver: (pairing ?? FakePairingResolver()).resolver, inlineConnection: inline
        )
    }

    @Test func identityIsTheAgents() {
        let agent = directAgent()
        let target = target(for: agent)

        #expect(target.id == agent.id)
        #expect(target.displayName == agent.name)
        #expect(target.handle == agent.syntheticEmail)
    }

    @Test(arguments: TransportKind.allCases)
    func kindSelectsTheAdapter(kind: TransportKind) {
        let made = FakeTransport()
        var requested: [TransportKind] = []
        let target = target(for: directAgent(kind: kind), factory: { kind in
            requested.append(kind)
            return made
        })
        #expect(requested.isEmpty) // only when the engine asks

        let transport = target.makeTransport()
        #expect(requested == [kind])
        #expect(transport === made)
    }

    @Test func directTargetConnectsToItsRoomWithItsToken() async throws {
        let agent = directAgent()
        let keychain = InMemoryKeychain()
        try keychain.setToken("room-token", for: KeychainTokenRef(directTokenForAgentID: agent.id))

        let connection = try await target(for: agent, keychain: keychain).connect()
        #expect(connection == CallConnection(url: room, token: "room-token"))
    }

    @Test func directTargetWithoutTokenThrowsAuthenticationFailed() async throws {
        let target = target(for: directAgent())
        await #expect(throws: TransportError.authenticationFailed) { try await target.connect() }
    }

    @Test func directTargetWithoutURLThrowsConnectionFailed() async throws {
        let agent = Agent(name: "Echo Bot", detail: "", transportKind: .daily)
        let keychain = InMemoryKeychain()
        try keychain.setToken("room-token", for: KeychainTokenRef(directTokenForAgentID: agent.id))

        let target = target(for: agent, keychain: keychain)
        await #expect(throws: TransportError.connectionFailed("No room URL or pairing endpoint")) {
            try await target.connect()
        }
    }

    @Test func directSecretIsCapturedWhenTheTargetIsMade() async throws {
        let agent = directAgent()
        let keychain = InMemoryKeychain()
        let ref = KeychainTokenRef(directTokenForAgentID: agent.id)
        try keychain.setToken("room-token", for: ref)
        let target = target(for: agent, keychain: keychain)

        try keychain.setToken("rotated", for: ref)
        #expect(try await target.connect().token == "room-token")
        #expect(try await target.connect().token == "room-token") // same on every attempt
    }

    @Test func pairingTargetPairsWithTheAPIKeyAndKind() async throws {
        let agent = pairingAgent()
        let keychain = InMemoryKeychain()
        try keychain.setToken("api-key", for: KeychainTokenRef(account: agent.keychainTokenRef))
        let pairing = FakePairingResolver()
        let target = target(for: agent, keychain: keychain, pairing: pairing)

        let connection = try await target.connect()
        _ = try await target.connect()

        #expect(connection == CallConnection(url: URL(string: "https://example.daily.co/paired")!, token: "paired-token"))
        let expected = FakePairingResolver.Request(endpoint: endpoint, apiKey: "api-key", kind: .livekit)
        #expect(pairing.requests == [expected, expected]) // re-paired per attempt
    }

    @Test func unauthorizedPairingMapsToAuthenticationFailed() async throws {
        let pairing = FakePairingResolver()
        pairing.result = .failure(PairingError.unauthorized)
        let target = target(for: pairingAgent(), pairing: pairing)

        await #expect(throws: TransportError.authenticationFailed) { try await target.connect() }
    }

    @Test(arguments: [PairingError.invalidResponse, .server(503), .missingCredentials])
    func otherPairingErrorsMapToConnectionFailed(error: PairingError) async throws {
        let pairing = FakePairingResolver()
        pairing.result = .failure(error)
        let target = target(for: pairingAgent(), pairing: pairing)

        await #expect(throws: TransportError.connectionFailed("pairing: \(error)")) { try await target.connect() }
    }

    @Test func nonPairingErrorsMapToConnectionFailed() async throws {
        let pairing = FakePairingResolver()
        let underlying = URLError(.notConnectedToInternet)
        pairing.result = .failure(underlying)
        let target = target(for: pairingAgent(), pairing: pairing)

        let thrown = await #expect(throws: TransportError.self) { try await target.connect() }
        if case .connectionFailed = thrown {} else {
            Issue.record("Expected .connectionFailed, got \(String(describing: thrown))")
        }
    }

    @Test func inlineConnectionWinsWithoutPairing() async throws {
        let pairing = FakePairingResolver()
        let inline = CallConnection(url: URL(string: "https://example.daily.co/inbound-room")!, token: "push-token")
        let target = target(for: pairingAgent(), pairing: pairing, inline: inline)

        #expect(try await target.connect() == inline)
        #expect(pairing.requests.isEmpty)
    }
}
