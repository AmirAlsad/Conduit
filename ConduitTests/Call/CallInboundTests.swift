//
//  CallInboundTests.swift
//  ConduitTests
//
//  Agent-initiated inbound calls: a VoIP push rings via CallKit, the user answers,
//  and the transport connects with the resolved target's credentials. Decline and
//  unknown-target paths are asserted too. The push round-trip itself is
//  device-only; this drives the coordinator against fakes at simulator speed.
//

import Foundation
import Testing
@testable import Conduit

@MainActor
struct CallInboundTests {

    private let statusEndpoint = URL(string: "https://engine.example.com/inbound/status/live")!

    @Test func receiveCallRingsAndResolvesAgent() async throws {
        let h = CoordinatorHarness()
        let callID = UUID()
        await h.coordinator.receiveCall(h.payload(callID: callID))

        #expect(h.coordinator.state == .incomingRinging)
        #expect(h.coordinator.activeCall?.targetID == h.target.id)
        #expect(h.coordinator.activeCall?.direction == .incoming)
        #expect(h.provider.reportedIncoming.map(\.id) == [callID])
        #expect(h.provider.reportedIncoming.first?.handle == CallHandle(value: h.target.handle))
        #expect(h.interruption.isObserving)
        #expect(h.delegate.resolved == [IncomingCall(
            callID: callID, targetID: h.target.id, displayName: "Agent", handle: "agent", connection: nil
        )])
    }

    @Test func answerConnectsViaAgentDirectConfig() async throws {
        let h = CoordinatorHarness()
        await h.coordinator.receiveCall(h.payload())
        await h.coordinator.answer()

        #expect(h.transport.connectCount == 1)
        #expect(h.target.connectCount == 1)
        #expect(h.transport.lastConnection == h.target.connection)
        #expect(h.coordinator.state.isConnecting)
        #expect(h.delegate.transitions == ["idle→incomingRinging", "incomingRinging→connecting"])
    }

    @Test func answerWithInlineCredentialsJoinsDirectly() async throws {
        let h = CoordinatorHarness()
        let room = URL(string: "https://example.daily.co/inbound-room")!
        await h.coordinator.receiveCall(h.payload(roomURL: room, token: "push-token"))

        // The inline room rides to the host, whose target joins it (AgentCallHostTests).
        #expect(h.delegate.resolved.first?.connection == CallConnection(url: room, token: "push-token"))
    }

    @Test func answeredCallConnectsAndLogsIncoming() async throws {
        let h = CoordinatorHarness()
        await h.coordinator.receiveCall(h.payload())
        await h.coordinator.answer()
        h.coordinator.handle(.connected)

        #expect(h.coordinator.state.isConnected)
        #expect(h.provider.reportedConnected.isEmpty) // incoming connects via answer-action

        await h.coordinator.endCall()
        let record = try #require(h.delegate.records.first)
        #expect(record.direction == .incoming)
        #expect(record.outcome == .completed)
        #expect(record.failureReason == nil)
        #expect(record.missedReason == nil)
    }

    @Test func answerViaSystemDelegateConnects() async throws {
        let h = CoordinatorHarness()
        await h.coordinator.receiveCall(h.payload())

        h.provider.simulateAnswerCall(UUID()) // the real CXAnswerCallAction path

        await waitUntil { h.transport.connectCount > 0 }
        #expect(h.transport.connectCount == 1)
    }

    @Test func declineWhileRingingLogsDeclined() async throws {
        let h = CoordinatorHarness()
        let callID = UUID()
        await h.coordinator.receiveCall(h.payload(callID: callID))

        h.coordinator.providerPerformEndCall(callID) // system decline

        #expect(h.coordinator.state.endedOutcome == .declined)
        let record = try #require(h.delegate.records.first)
        #expect(record.direction == .incoming)
        #expect(record.outcome == .declined)
        #expect(record.missedReason == nil)
        #expect(!h.interruption.isObserving)
    }

    @Test func unknownAgentReportsThenFails() async throws {
        let h = CoordinatorHarness()
        let unknownID = UUID()
        await h.coordinator.receiveCall(h.payload(targetID: unknownID))

        #expect(h.provider.reportedIncoming.count == 1) // reported before failing
        #expect(h.provider.reportedIncoming.first?.handle == CallHandle(value: "agent"))
        #expect(h.coordinator.state.failureReason == .unknown)
        #expect(h.coordinator.activeCall == nil)
        // Recorded against the pushed id; the host finds no agent and writes no row.
        #expect(h.delegate.records.map(\.targetID) == [unknownID])
        #expect(h.delegate.records.first?.failureReason == .unknown)
    }

    @Test func receiveCallWhileBusyReportsAndImmediatelyEnds() async throws {
        // iOS terminates the app (killing the active call) if a VoIP push isn't
        // reported to CallKit — busy means report-then-end, never silent ignore.
        let h = CoordinatorHarness()
        await h.placeCall() // already in a call
        let busyCallID = UUID()
        await h.coordinator.receiveCall(h.payload(callID: busyCallID))

        #expect(h.coordinator.state.isConnecting) // active call untouched
        #expect(h.provider.reportedIncoming.map(\.id) == [busyCallID])
        #expect(h.provider.reportedEnded.map(\.id) == [busyCallID])
        #expect(h.provider.reportedEnded.first?.reason == .unanswered)

        // The missed ring is recorded as an incoming no-answer the user never saw.
        #expect(h.delegate.records.count == 1)
        let record = try #require(h.delegate.records.first)
        #expect(record.targetID == h.target.id)
        #expect(record.direction == .incoming)
        #expect(record.outcome == .noAnswer)
        #expect(record.duration == 0)
        #expect(record.missedReason == .busy)
        #expect(h.delegate.transitions == ["idle→dialing", "dialing→connecting"]) // no T for the busy ring
    }

    @Test func focusFilteredRingLogsMissedAndReturnsToIdle() async throws {
        // Focus/DND makes reportNewIncomingCall fail with a filtered error: not a
        // failure — record a missed call and stay ready to ring again.
        let h = CoordinatorHarness()
        h.provider.reportIncomingError = IncomingCallReportError.filteredByFocus
        await h.coordinator.receiveCall(h.payload())

        #expect(h.coordinator.state == .idle) // not stuck in .failed
        #expect(!h.interruption.isObserving)
        #expect(h.delegate.records.count == 1)
        let record = try #require(h.delegate.records.first)
        #expect(record.direction == .incoming)
        #expect(record.outcome == .noAnswer)
        #expect(record.missedReason == .filteredByFocus)
        #expect(h.delegate.transitions == ["idle→incomingRinging", "incomingRinging→idle"])

        // A later push (Focus off) rings normally.
        h.provider.reportIncomingError = nil
        await h.coordinator.receiveCall(h.payload())
        #expect(h.coordinator.state == .incomingRinging)
    }

    // MARK: - Ring-status receipts (push carried a status_url)

    @Test func answerReportsAnsweredReceiptWithBearer() async throws {
        let h = CoordinatorHarness()
        h.delegate.bearers[h.target.id] = "agent-api-key"
        let callID = UUID()
        await h.coordinator.receiveCall(h.payload(callID: callID, statusURL: statusEndpoint))
        await h.coordinator.answer()

        #expect(h.ringStatusReporter.reports == [
            .init(status: .answered, callID: callID, endpoint: statusEndpoint, apiKey: "agent-api-key")
        ])
        #expect(h.delegate.bearerRequests == [h.target.id])
    }

    @Test func declineReportsDeclinedReceipt() async throws {
        let h = CoordinatorHarness()
        let callID = UUID()
        await h.coordinator.receiveCall(h.payload(callID: callID, statusURL: statusEndpoint))
        h.coordinator.providerPerformEndCall(callID)

        #expect(h.ringStatusReporter.reports.map(\.status) == [.declined])
        #expect(h.ringStatusReporter.reports.first?.callID == callID)
        #expect(h.ringStatusReporter.reports.first?.apiKey == "") // the host had no bearer
    }

    @Test func busyPushReportsBusyReceipt() async throws {
        let h = CoordinatorHarness()
        await h.placeCall()
        let busyCallID = UUID()
        await h.coordinator.receiveCall(h.payload(callID: busyCallID, statusURL: statusEndpoint))

        #expect(h.ringStatusReporter.reports.map(\.status) == [.busy])
        #expect(h.ringStatusReporter.reports.first?.callID == busyCallID)
    }

    @Test func focusFilteredRingReportsSuppressedReceipt() async throws {
        let h = CoordinatorHarness()
        h.provider.reportIncomingError = IncomingCallReportError.filteredByFocus
        let callID = UUID()
        await h.coordinator.receiveCall(h.payload(callID: callID, statusURL: statusEndpoint))

        #expect(h.ringStatusReporter.reports.map(\.status) == [.suppressedByFocus])
        #expect(h.ringStatusReporter.reports.first?.callID == callID)
    }

    @Test func completedCallReportsOnlyTheAnswerReceipt() async throws {
        // The receipt describes the RING's outcome; a normal hang-up after a
        // connected call must not produce a second (declined) report.
        let h = CoordinatorHarness()
        await h.coordinator.receiveCall(h.payload(statusURL: statusEndpoint))
        await h.coordinator.answer()
        h.coordinator.handle(.connected)
        await h.coordinator.endCall()

        #expect(h.ringStatusReporter.reports.map(\.status) == [.answered])
    }

    @Test func noStatusURLReportsNothing() async throws {
        let h = CoordinatorHarness()
        let callID = UUID()
        await h.coordinator.receiveCall(h.payload(callID: callID))
        h.coordinator.providerPerformEndCall(callID)

        #expect(h.ringStatusReporter.reports.isEmpty)
        #expect(h.delegate.bearerRequests.isEmpty) // only asked when a receipt is sent
    }
}
