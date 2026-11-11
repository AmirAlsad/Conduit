//
//  CallCredentialResolutionTests.swift
//  ConduitTests
//
//  The credential step between creating the transport and joining the room:
//  pairing per attempt, direct/inline reuse, error mapping, and the races where
//  CallKit activation or the user's End lands while credentials are in flight.
//

import Foundation
import Testing
@testable import Conduit

@MainActor
struct CallCredentialResolutionTests {

    private let endpoint = URL(string: "https://engine.example.com/connect/live")!
    private let pairedRoom = CallConnection(url: URL(string: "https://example.daily.co/paired")!, token: "paired-token")

    // MARK: - Ordering against CallKit activation

    @Test func activationDuringSuspendedResolveAttachesTheTransport() async throws {
        let h = try CoordinatorHarness(pairingEndpoint: endpoint)
        h.pairing.suspend = true

        let place = Task { await h.coordinator.placeCall(h.agent) }
        await waitUntil { h.pairing.requests.count == 1 }
        #expect(h.transportRequests.kinds == [.daily]) // created before the fetch
        #expect(h.transport.connectCount == 0)

        h.provider.simulateActivate(FakeAudioSession(hasExternalAudioRoute: false))
        await h.coordinator.awaitPendingActivation()
        #expect(h.transport.isAudioAttached)

        h.pairing.release()
        await place.value

        #expect(h.transport.connectCount == 1)
        #expect(h.transport.lastConnection == pairedRoom)
        #expect(h.transport.isAudioAttached)
    }

    // MARK: - Ending while credentials are in flight

    @Test func endDuringSuspendedFirstResolveNeverJoinsTheRoom() async throws {
        let h = try CoordinatorHarness(pairingEndpoint: endpoint)
        h.pairing.suspend = true

        let place = Task { await h.coordinator.placeCall(h.agent) }
        await waitUntil { h.pairing.requests.count == 1 }
        await h.coordinator.endCall()
        #expect(h.coordinator.state.endedOutcome == .canceled)

        h.pairing.release()
        await place.value

        #expect(h.transport.connectCount == 0)
        #expect(h.coordinator.state.endedOutcome == .canceled)
        let entries = try h.loggedEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.outcome == .canceled)
    }

    @Test(arguments: [false, true])
    func endDuringSuspendedRetryKeepsTheCallTerminal(retryFails: Bool) async throws {
        let h = try CoordinatorHarness(pairingEndpoint: endpoint)
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.pairing.suspend = true
        h.coordinator.handle(.disconnected(reason: .networkDropped))
        #expect(h.coordinator.state.reconnectingAttempt == 1)
        await waitUntil { h.pairing.requests.count == 2 }
        let retry = try #require(h.coordinator.reconnectTask)

        await h.coordinator.endCall()
        #expect(h.coordinator.state.endedOutcome == .completed)

        if retryFails { h.pairing.result = .failure(PairingError.server(503)) }
        h.pairing.release()
        await retry.value

        #expect(h.coordinator.state.endedOutcome == .completed)
        #expect(h.coordinator.reconnectTask == nil)
        #expect(h.transport.connectCount == 1) // the retry never joined
        #expect(h.announcer.startedRepeating.filter { $0 == .retrying }.count == 1)
        #expect(try h.loggedEntries().count == 1)
    }

    // MARK: - Once per attempt

    @Test func resolverRunsOncePerReconnectAttempt() async throws {
        let h = try CoordinatorHarness(pairingEndpoint: endpoint)
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)
        #expect(h.pairing.requests.count == 1)

        h.coordinator.handle(.disconnected(reason: .networkDropped))
        await h.coordinator.awaitPendingReconnect()
        #expect(h.pairing.requests.count == 2)
        #expect(h.transport.connectCount == 2)

        h.coordinator.handle(.disconnected(reason: .networkDropped))
        await h.coordinator.awaitPendingReconnect()
        #expect(h.pairing.requests.count == 3)
        #expect(h.transport.connectCount == 3)

        let expected = FakePairingResolver.Request(endpoint: endpoint, apiKey: "valid-token", kind: .daily)
        #expect(h.pairing.requests == Array(repeating: expected, count: 3))
        #expect(h.transport.lastConnection == pairedRoom)
        #expect(h.transportRequests.kinds == [.daily]) // one transport, reused by every attempt
    }

    @Test func directCredentialsRepeatOnEveryAttempt() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)
        let first = try #require(h.transport.lastConnection)
        #expect(first == CallConnection(url: try #require(h.agent.connectionURL), token: "valid-token"))

        h.coordinator.handle(.disconnected(reason: .networkDropped))
        await h.coordinator.awaitPendingReconnect()

        #expect(h.transport.connectCount == 2)
        #expect(h.transport.lastConnection == first)
        #expect(h.pairing.requests.isEmpty)
    }

    @Test func inlinePushCredentialsRepeatOnEveryAttempt() async throws {
        let h = try CoordinatorHarness()
        let room = URL(string: "https://example.daily.co/inbound-room")!
        await h.coordinator.receiveCall(IncomingCallPayload(
            agentID: h.agent.id, callID: UUID(), roomURL: room, token: "push-token", statusURL: nil
        ))
        await h.coordinator.answer()
        h.coordinator.handle(.connected)

        h.coordinator.handle(.disconnected(reason: .networkDropped))
        await h.coordinator.awaitPendingReconnect()

        #expect(h.transport.connectCount == 2)
        #expect(h.transport.lastConnection == CallConnection(url: room, token: "push-token"))
        #expect(h.pairing.requests.isEmpty)
    }

    // MARK: - Error mapping

    @Test func unauthorizedPairingFailsWithBadToken() async throws {
        let h = try CoordinatorHarness(pairingEndpoint: endpoint)
        h.pairing.result = .failure(PairingError.unauthorized)
        await h.coordinator.placeCall(h.agent)

        #expect(h.coordinator.state.failureReason == .badToken)
        #expect(h.transport.connectCount == 0)
        #expect(try h.loggedEntries().first?.failureReason == .badToken)
    }

    @Test(arguments: [PairingError.invalidResponse, .server(503), .missingCredentials])
    func otherPairingFailuresFailWithTransportError(error: PairingError) async throws {
        let h = try CoordinatorHarness(pairingEndpoint: endpoint)
        h.pairing.result = .failure(error)
        await h.coordinator.placeCall(h.agent)

        #expect(h.coordinator.state.failureReason == .transportError)
        #expect(h.transport.connectCount == 0)
    }

    @Test func pairingAgentWithoutAPIKeyStillPairs() async throws {
        let h = try CoordinatorHarness(token: nil, pairingEndpoint: endpoint)
        await h.coordinator.placeCall(h.agent)

        #expect(h.pairing.requests.map(\.apiKey) == [""]) // an open endpoint is allowed
        #expect(h.transport.lastConnection == pairedRoom)
        #expect(h.coordinator.state.isConnecting)
    }
}
