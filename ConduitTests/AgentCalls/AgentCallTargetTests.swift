//
//  AgentCallTargetTests.swift
//  ConduitTests
//
//  `Agent.callTarget(...)`: the identity CallKit sees, the adapter the agent's
//  kind selects, the ring preparation it allows, and the credential step — direct
//  room + token, pairing (with its error mapping and the ring a request made while
//  ringing is for), or inline push credentials — for every `ConnectRequest`
//  purpose, without the engine.
//

import Foundation
import Testing
@testable import Conduit
import ConduitCallEngine
import ConduitCallEngineTesting

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
        ringPreparation: RingPreparation = .none,
        factory: @escaping (TransportKind) -> CallTransport = { _ in FakeTransport() }
    ) -> CallTarget {
        agent.callTarget(
            keychain: keychain ?? InMemoryKeychain(), transportFactory: factory,
            pairingResolver: (pairing ?? FakePairingResolver()).resolver, inlineConnection: inline,
            ringPreparation: ringPreparation
        )
    }

    private nonisolated static let callID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    /// Every purpose the engine can ask with, as it asks for an incoming call.
    nonisolated static let everyPurpose: [ConnectRequest] = [
        .outgoing,
        ConnectRequest(purpose: .answered, callID: callID),
        ConnectRequest(purpose: .ringing(joinsBeforeAnswer: false), callID: callID),
        ConnectRequest(purpose: .ringing(joinsBeforeAnswer: true), callID: callID),
        ConnectRequest(purpose: .reconnect(attempt: 1), callID: callID),
        ConnectRequest(purpose: .reconnect(attempt: 3), callID: nil),
    ]

    @Test func identityIsTheAgents() {
        let agent = directAgent()
        let target = target(for: agent)

        #expect(target.id == agent.id)
        #expect(target.displayName == agent.name)
        #expect(target.handle == agent.syntheticEmail)
    }

    @Test func allowsNoRingPreparationUnlessAsked() {
        #expect(target(for: pairingAgent()).ringPreparation == .none)
    }

    @Test(arguments: RingPreparation.allCases)
    func allowsTheRingPreparationItIsGiven(preparation: RingPreparation) {
        #expect(target(for: pairingAgent(), ringPreparation: preparation).ringPreparation == preparation)
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

        let connection = try await target(for: agent, keychain: keychain).connect(.outgoing)
        #expect(connection == CallConnection(url: room, token: "room-token"))
    }

    @Test func directTargetWithoutTokenThrowsAuthenticationFailed() async throws {
        let target = target(for: directAgent())
        await #expect(throws: TransportError.authenticationFailed) { try await target.connect(.outgoing) }
    }

    @Test func directTargetWithoutURLThrowsConnectionFailed() async throws {
        let agent = Agent(name: "Echo Bot", detail: "", transportKind: .daily)
        let keychain = InMemoryKeychain()
        try keychain.setToken("room-token", for: KeychainTokenRef(directTokenForAgentID: agent.id))

        let target = target(for: agent, keychain: keychain)
        await #expect(throws: TransportError.connectionFailed("No room URL or pairing endpoint")) {
            try await target.connect(.outgoing)
        }
    }

    @Test func directSecretIsCapturedWhenTheTargetIsMade() async throws {
        let agent = directAgent()
        let keychain = InMemoryKeychain()
        let ref = KeychainTokenRef(directTokenForAgentID: agent.id)
        try keychain.setToken("room-token", for: ref)
        let target = target(for: agent, keychain: keychain)

        try keychain.setToken("rotated", for: ref)
        #expect(try await target.connect(.outgoing).token == "room-token")
        #expect(try await target.connect(.outgoing).token == "room-token") // same on every attempt
    }

    @Test func pairingTargetPairsWithTheAPIKeyAndKind() async throws {
        let agent = pairingAgent()
        let keychain = InMemoryKeychain()
        try keychain.setToken("api-key", for: KeychainTokenRef(account: agent.keychainTokenRef))
        let pairing = FakePairingResolver()
        let target = target(for: agent, keychain: keychain, pairing: pairing)

        let connection = try await target.connect(.outgoing)
        _ = try await target.connect(.outgoing)

        #expect(connection == CallConnection(url: URL(string: "https://example.daily.co/paired")!, token: "paired-token"))
        let expected = FakePairingResolver.Request(endpoint: endpoint, apiKey: "api-key", kind: .livekit)
        #expect(pairing.requests == [expected, expected]) // re-paired per attempt
    }

    @Test func unauthorizedPairingMapsToAuthenticationFailed() async throws {
        let pairing = FakePairingResolver()
        pairing.result = .failure(PairingError.unauthorized)
        let target = target(for: pairingAgent(), pairing: pairing)

        await #expect(throws: TransportError.authenticationFailed) { try await target.connect(.outgoing) }
    }

    @Test(arguments: [PairingError.invalidResponse, .server(503), .missingCredentials])
    func otherPairingErrorsMapToConnectionFailed(error: PairingError) async throws {
        let pairing = FakePairingResolver()
        pairing.result = .failure(error)
        let target = target(for: pairingAgent(), pairing: pairing)

        await #expect(throws: TransportError.connectionFailed("pairing: \(error)")) { try await target.connect(.outgoing) }
    }

    @Test func nonPairingErrorsMapToConnectionFailed() async throws {
        let pairing = FakePairingResolver()
        let underlying = URLError(.notConnectedToInternet)
        pairing.result = .failure(underlying)
        let target = target(for: pairingAgent(), pairing: pairing)

        let thrown = await #expect(throws: TransportError.self) { try await target.connect(.outgoing) }
        if case .connectionFailed = thrown {} else {
            Issue.record("Expected .connectionFailed, got \(String(describing: thrown))")
        }
    }

    @Test(arguments: everyPurpose)
    func inlineConnectionWinsWithoutPairing(request: ConnectRequest) async throws {
        let pairing = FakePairingResolver()
        let inline = CallConnection(url: URL(string: "https://example.daily.co/inbound-room")!, token: "push-token")
        let target = target(for: pairingAgent(), pairing: pairing, inline: inline)

        #expect(try await target.connect(request) == inline)
        #expect(pairing.requests.isEmpty)
    }

    // MARK: - What each request tells the pairing endpoint

    @Test(arguments: [
        (ConnectRequest.outgoing, PairingRing?.none),
        (ConnectRequest(purpose: .answered, callID: callID), nil),
        (ConnectRequest(purpose: .ringing(joinsBeforeAnswer: false), callID: callID),
         PairingRing(callID: callID, awaitAnswer: false)),
        (ConnectRequest(purpose: .ringing(joinsBeforeAnswer: true), callID: callID),
         PairingRing(callID: callID, awaitAnswer: true)),
        (ConnectRequest(purpose: .reconnect(attempt: 1), callID: callID), nil),
        (ConnectRequest(purpose: .reconnect(attempt: 2), callID: nil), nil),
    ])
    func pairingIsToldTheRingOnlyWhileRinging(request: ConnectRequest, ring: PairingRing?) async throws {
        let agent = pairingAgent()
        let keychain = InMemoryKeychain()
        try keychain.setToken("api-key", for: KeychainTokenRef(account: agent.keychainTokenRef))
        let pairing = FakePairingResolver()

        _ = try await target(for: agent, keychain: keychain, pairing: pairing).connect(request)

        #expect(pairing.requests == [
            FakePairingResolver.Request(endpoint: endpoint, apiKey: "api-key", kind: .livekit, ring: ring),
        ])
    }

    @Test func aRingingRequestWithoutACallIDCarriesNoRing() async throws {
        let pairing = FakePairingResolver()
        let request = ConnectRequest(purpose: .ringing(joinsBeforeAnswer: true), callID: nil)

        _ = try await target(for: pairingAgent(), pairing: pairing).connect(request)

        #expect(pairing.requests.map(\.ring) == [nil])
    }

    @Test(arguments: everyPurpose)
    func directTargetAnswersEveryPurposeWithItsRoom(request: ConnectRequest) async throws {
        let agent = directAgent()
        let keychain = InMemoryKeychain()
        try keychain.setToken("room-token", for: KeychainTokenRef(directTokenForAgentID: agent.id))

        let connection = try await target(for: agent, keychain: keychain).connect(request)
        #expect(connection == CallConnection(url: room, token: "room-token"))
    }
}
