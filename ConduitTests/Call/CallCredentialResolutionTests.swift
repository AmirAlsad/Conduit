//
//  CallCredentialResolutionTests.swift
//  ConduitTests
//
//  The credential step between creating the transport and joining the room
//  (`CallTarget.connect`): once per attempt, and the races where CallKit
//  activation or the user's End lands while credentials are in flight. What an
//  agent's target resolves to is in AgentCallTargetTests / AgentCallHostTests.
//

import Foundation
import Testing
@testable import Conduit

@MainActor
struct CallCredentialResolutionTests {

    // MARK: - Ordering against CallKit activation

    @Test func activationDuringSuspendedResolveAttachesTheTransport() async throws {
        let h = CoordinatorHarness()
        h.target.suspend = true

        let place = Task { await h.placeCall() }
        await waitUntil { h.target.connectCount == 1 }
        #expect(h.target.connectCount == 1)
        #expect(h.target.makeTransportCount == 1) // created before the fetch
        #expect(h.transport.connectCount == 0)

        h.provider.simulateActivate(FakeAudioSession(hasExternalAudioRoute: false))
        await h.coordinator.awaitPendingActivation()
        #expect(h.transport.isAudioAttached)

        h.target.release()
        await place.value

        #expect(h.transport.connectCount == 1)
        #expect(h.transport.lastConnection == h.target.connection)
        #expect(h.transport.isAudioAttached)
    }

    // MARK: - Ending while credentials are in flight

    @Test func endDuringSuspendedFirstResolveNeverJoinsTheRoom() async throws {
        let h = CoordinatorHarness()
        h.target.suspend = true

        let place = Task { await h.placeCall() }
        await waitUntil { h.target.connectCount == 1 }
        #expect(h.target.connectCount == 1)
        await h.coordinator.endCall()
        #expect(h.coordinator.state.endedOutcome == .canceled)

        h.target.release()
        await place.value

        #expect(h.transport.connectCount == 0)
        #expect(h.coordinator.state.endedOutcome == .canceled)
        #expect(h.delegate.records.map(\.outcome) == [.canceled])
    }

    @Test(arguments: [false, true])
    func endDuringSuspendedRetryKeepsTheCallTerminal(retryFails: Bool) async throws {
        let h = CoordinatorHarness()
        await h.placeCall()
        h.coordinator.handle(.connected)

        h.target.suspend = true
        h.coordinator.handle(.disconnected(reason: .networkDropped))
        #expect(h.coordinator.state.reconnectingAttempt == 1)
        await waitUntil { h.target.connectCount == 2 }
        #expect(h.target.connectCount == 2)
        let retry = try #require(h.coordinator.reconnectTask)

        await h.coordinator.endCall()
        #expect(h.coordinator.state.endedOutcome == .completed)

        if retryFails { h.target.error = TransportError.connectionFailed("pairing: server(503)") }
        h.target.release()
        await retry.value

        #expect(h.coordinator.state.endedOutcome == .completed)
        #expect(h.coordinator.reconnectTask == nil)
        #expect(h.transport.connectCount == 1) // the retry never joined
        #expect(h.delegate.transitions.filter { $0.contains("→reconnecting") } == ["connected→reconnecting(1)"])
        #expect(h.delegate.transitions.last == "reconnecting(1)→ended(completed)")
        #expect(h.delegate.records.count == 1)
    }

    // MARK: - Once per attempt

    @Test func resolverRunsOncePerReconnectAttempt() async throws {
        let h = CoordinatorHarness()
        await h.placeCall()
        h.coordinator.handle(.connected)
        #expect(h.target.connectCount == 1)

        h.coordinator.handle(.disconnected(reason: .networkDropped))
        await h.coordinator.awaitPendingReconnect()
        #expect(h.target.connectCount == 2)
        #expect(h.transport.connectCount == 2)

        h.coordinator.handle(.disconnected(reason: .networkDropped))
        await h.coordinator.awaitPendingReconnect()
        #expect(h.target.connectCount == 3)
        #expect(h.transport.connectCount == 3)

        #expect(h.transport.lastConnection == h.target.connection)
        #expect(h.target.makeTransportCount == 1) // one transport, reused by every attempt
    }
}
