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
        token: String? = nil,
        statusURL: URL? = nil
    ) -> IncomingCallPayload {
        IncomingCallPayload(
            agentID: h.agent.id, callID: callID, roomURL: roomURL, token: token, statusURL: statusURL
        )
    }

    private let statusEndpoint = URL(string: "https://engine.example.com/inbound/status/live")!

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
        let unknown = IncomingCallPayload(
            agentID: UUID(), callID: UUID(), roomURL: nil, token: nil, statusURL: nil
        )
        await h.coordinator.receiveCall(unknown)

        #expect(h.provider.reportedIncoming.count == 1) // reported before failing
        #expect(h.coordinator.state.failureReason == .unknown)
        #expect(try h.loggedEntries().isEmpty) // no agent to attribute the log to
    }

    @Test func receiveCallWhileBusyReportsAndImmediatelyEnds() async throws {
        // iOS terminates the app (killing the active call) if a VoIP push isn't
        // reported to CallKit — busy means report-then-end, never silent ignore.
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent) // already in a call
        let busyCallID = UUID()
        await h.coordinator.receiveCall(payload(for: h, callID: busyCallID))

        #expect(h.coordinator.state.isConnecting) // active call untouched
        #expect(h.provider.reportedIncoming.map(\.id) == [busyCallID])
        #expect(h.provider.reportedEnded.map(\.id) == [busyCallID])
        #expect(h.provider.reportedEnded.first?.reason == .unanswered)

        // The missed ring lands in Recents as an incoming no-answer, with a
        // quiet missed-call notification.
        let entries = try h.loggedEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.direction == .incoming)
        #expect(entries.first?.outcome == .noAnswer)
        #expect(h.missedNotifier.missedAgentNames == [h.agent.name])
    }

    @Test func focusFilteredRingLogsMissedAndReturnsToIdle() async throws {
        // Focus/DND makes reportNewIncomingCall fail with a filtered error: not a
        // failure — log a missed call, notify quietly, and stay ready to ring again.
        let h = try CoordinatorHarness()
        h.provider.reportIncomingError = IncomingCallReportError.filteredByFocus
        await h.coordinator.receiveCall(payload(for: h))

        #expect(h.coordinator.state == .idle) // not stuck in .failed
        #expect(!h.interruption.isObserving)
        let entries = try h.loggedEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.direction == .incoming)
        #expect(entries.first?.outcome == .noAnswer)
        #expect(h.missedNotifier.missedAgentNames == [h.agent.name])

        // A later push (Focus off) rings normally.
        h.provider.reportIncomingError = nil
        await h.coordinator.receiveCall(payload(for: h))
        #expect(h.coordinator.state == .incomingRinging)
    }

    // MARK: - Ring-status receipts (push carried a status_url)

    @Test func answerReportsAnsweredReceiptWithBearer() async throws {
        let h = try CoordinatorHarness()
        try h.keychain.setToken("agent-api-key", for: KeychainTokenRef(account: h.agent.keychainTokenRef))
        let callID = UUID()
        await h.coordinator.receiveCall(payload(for: h, callID: callID, statusURL: statusEndpoint))
        await h.coordinator.answer()

        #expect(h.ringStatusReporter.reports == [
            .init(status: .answered, callID: callID, endpoint: statusEndpoint, apiKey: "agent-api-key")
        ])
    }

    @Test func declineReportsDeclinedReceipt() async throws {
        let h = try CoordinatorHarness()
        let callID = UUID()
        await h.coordinator.receiveCall(payload(for: h, callID: callID, statusURL: statusEndpoint))
        h.coordinator.providerPerformEndCall(callID)

        #expect(h.ringStatusReporter.reports.map(\.status) == [.declined])
        #expect(h.ringStatusReporter.reports.first?.callID == callID)
    }

    @Test func busyPushReportsBusyReceipt() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        let busyCallID = UUID()
        await h.coordinator.receiveCall(payload(for: h, callID: busyCallID, statusURL: statusEndpoint))

        #expect(h.ringStatusReporter.reports.map(\.status) == [.busy])
        #expect(h.ringStatusReporter.reports.first?.callID == busyCallID)
    }

    @Test func focusFilteredRingReportsSuppressedReceipt() async throws {
        let h = try CoordinatorHarness()
        h.provider.reportIncomingError = IncomingCallReportError.filteredByFocus
        let callID = UUID()
        await h.coordinator.receiveCall(payload(for: h, callID: callID, statusURL: statusEndpoint))

        #expect(h.ringStatusReporter.reports.map(\.status) == [.suppressedByFocus])
        #expect(h.ringStatusReporter.reports.first?.callID == callID)
    }

    @Test func completedCallReportsOnlyTheAnswerReceipt() async throws {
        // The receipt describes the RING's outcome; a normal hang-up after a
        // connected call must not produce a second (declined) report.
        let h = try CoordinatorHarness()
        await h.coordinator.receiveCall(payload(for: h, statusURL: statusEndpoint))
        await h.coordinator.answer()
        h.coordinator.handle(.connected)
        await h.coordinator.endCall()

        #expect(h.ringStatusReporter.reports.map(\.status) == [.answered])
    }

    @Test func noStatusURLReportsNothing() async throws {
        let h = try CoordinatorHarness()
        let callID = UUID()
        await h.coordinator.receiveCall(payload(for: h, callID: callID))
        h.coordinator.providerPerformEndCall(callID)

        #expect(h.ringStatusReporter.reports.isEmpty)
    }
}
