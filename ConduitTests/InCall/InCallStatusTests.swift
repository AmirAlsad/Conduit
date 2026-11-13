//
//  InCallStatusTests.swift
//  ConduitTests
//
//  The in-call status-line copy mapping. `.connected` and `.idle` carry no static
//  text (the view shows a live timer / no surface). An interrupted call shows
//  that instead.
//

import Foundation
import Testing
@testable import Conduit
import ConduitCallEngine

struct InCallStatusTests {
    @Test func connectedAndIdleHaveNoStaticText() {
        #expect(InCallStatus.text(for: .idle) == nil)
        #expect(InCallStatus.text(for: .connected(since: Date(timeIntervalSince1970: 0))) == nil)
    }

    @Test(arguments: [
        (CallState.dialing, "Calling…"),
        (CallState.connecting, "Connecting…"),
        (CallState.reconnecting(attempt: 2), "Reconnecting…"),
        (CallState.ended(.completed), "Call Ended"),
    ])
    func transientStatesMapToText(state: CallState, expected: String) {
        #expect(InCallStatus.text(for: state) == expected)
    }

    @Test(arguments: [
        (CallFailureReason.badToken, "Authentication failed"),
        (CallFailureReason.agentUnreachable, "Agent didn't join"),
        (CallFailureReason.lostConnection, "Connection lost"),
        (CallFailureReason.transportError, "Couldn't connect"),
        (CallFailureReason.unknown, "Call failed"),
    ])
    func failureReasonsMapToText(reason: CallFailureReason, expected: String) {
        #expect(InCallStatus.text(for: reason) == expected)
        #expect(InCallStatus.text(for: .failed(reason)) == expected)
    }

    @Test(arguments: [
        (CallFailureReason.badToken, "authentication"),
        (CallFailureReason.agentUnreachable, "agent didn't join"),
        (CallFailureReason.lostConnection, "connection lost"),
        (CallFailureReason.transportError, "couldn't connect"),
    ])
    func failureReasonsHaveLogRowQualifiers(reason: CallFailureReason, expected: String) {
        #expect(reason.shortLabel == expected)
    }

    @Test func unknownReasonHasNoQualifier() {
        #expect(CallFailureReason.unknown.shortLabel == nil)
    }

    @Test func everyFailureReasonHasAHint() {
        for reason in [CallFailureReason.badToken, .agentUnreachable, .lostConnection, .transportError, .unknown] {
            #expect(!reason.hint.isEmpty)
        }
    }

    @Test func agentUnreachableHintPointsAtTheAgentNotTheNetwork() {
        #expect(CallFailureReason.agentUnreachable.hint
            == "Conduit reached the call, but your agent never joined it. Check that your server starts the agent for each call.")
    }

    // MARK: - Paused

    @Test func anInterruptedCallIsPaused() {
        let state = CallState.connected(since: Date(timeIntervalSince1970: 0))
        #expect(InCallStatus.pausedText(for: state, isInterrupted: true) == "Paused")
        #expect(InCallStatus.pausedText(for: state, isInterrupted: false) == nil)
    }

    @Test(arguments: [CallState.ended(.completed), .failed(.lostConnection)])
    func anEndedCallIsNeverShownPaused(state: CallState) {
        #expect(InCallStatus.pausedText(for: state, isInterrupted: true) == nil)
    }
}
