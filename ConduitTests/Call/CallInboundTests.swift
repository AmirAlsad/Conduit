//
//  CallInboundTests.swift
//  ConduitTests
//
//  Agent-initiated inbound calls: a VoIP push rings via CallKit, the user answers,
//  and the transport connects (inline push credentials or the agent's own config).
//  Decline and unknown-agent paths are asserted too. The push round-trip itself is
//  device-only; this drives the coordinator against fakes at simulator speed.
//

import Foundation
import Testing
@testable import Conduit

@MainActor
struct CallInboundTests {

    private func payload(
        for h: CoordinatorHarness,
        callID: UUID = UUID(),
        roomURL: URL? = nil,
        token: String? = nil
    ) -> IncomingCallPayload {
        IncomingCallPayload(agentID: h.agent.id, callID: callID, roomURL: roomURL, token: token)
    }

    @Test func receiveCallRingsAndResolvesAgent() async throws {
        let h = try CoordinatorHarness()
        let callID = UUID()
        await h.coordinator.receiveCall(payload(for: h, callID: callID))

        #expect(h.coordinator.state == .incomingRinging)
        #expect(h.coordinator.activeAgent?.id == h.agent.id)
        #expect(h.provider.reportedIncoming.map(\.id) == [callID])
        #expect(h.interruption.isObserving)
    }

    @Test func answerConnectsViaAgentDirectConfig() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.receiveCall(payload(for: h))
        await h.coordinator.answer()

        #expect(h.transport.connectCount == 1)
        #expect(h.transport.lastConfig?.token == "valid-token")
        #expect(h.transport.lastConfig?.url == h.agent.connectionURL)
        #expect(h.coordinator.state.isConnecting)
    }

    @Test func answerWithInlineCredentialsJoinsDirectly() async throws {
        let h = try CoordinatorHarness()
        let room = URL(string: "https://example.daily.co/inbound-room")!
        await h.coordinator.receiveCall(payload(for: h, roomURL: room, token: "push-token"))
        await h.coordinator.answer()

        #expect(h.transport.lastConfig?.url == room)
        #expect(h.transport.lastConfig?.token == "push-token")
        #expect(h.transport.lastConfig?.pairingEndpoint == nil)
    }

    @Test func answeredCallConnectsAndLogsIncoming() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.receiveCall(payload(for: h))
        await h.coordinator.answer()
        h.coordinator.handle(.connected)

        #expect(h.coordinator.state.isConnected)
        #expect(h.provider.reportedConnected.isEmpty) // incoming connects via answer-action

        await h.coordinator.endCall()
        let entries = try h.loggedEntries()
        #expect(entries.first?.direction == .incoming)
        #expect(entries.first?.outcome == .completed)
    }

    @Test func answerViaSystemDelegateConnects() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.receiveCall(payload(for: h))

        h.provider.simulateAnswerCall(UUID()) // the real CXAnswerCallAction path

        await waitUntil { h.transport.connectCount > 0 }
        #expect(h.transport.connectCount == 1)
    }

    @Test func declineWhileRingingLogsDeclined() async throws {
        let h = try CoordinatorHarness()
        let callID = UUID()
        await h.coordinator.receiveCall(payload(for: h, callID: callID))

        h.coordinator.providerPerformEndCall(callID) // system decline

        #expect(h.coordinator.state.endedOutcome == .declined)
        let entries = try h.loggedEntries()
        #expect(entries.first?.direction == .incoming)
        #expect(entries.first?.outcome == .declined)
        #expect(!h.interruption.isObserving)
    }

    @Test func unknownAgentReportsThenFails() async throws {
        let h = try CoordinatorHarness()
        let unknown = IncomingCallPayload(agentID: UUID(), callID: UUID(), roomURL: nil, token: nil)
        await h.coordinator.receiveCall(unknown)

        #expect(h.provider.reportedIncoming.count == 1) // reported before failing
        #expect(h.coordinator.state.failureReason == .unknown)
        #expect(try h.loggedEntries().isEmpty) // no agent to attribute the log to
    }

    @Test func receiveCallIgnoredWhenNotIdle() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent) // already in a call
        await h.coordinator.receiveCall(payload(for: h))

        #expect(h.coordinator.state.isConnecting) // unchanged by the ignored inbound
        #expect(h.provider.reportedIncoming.isEmpty)
    }
}
