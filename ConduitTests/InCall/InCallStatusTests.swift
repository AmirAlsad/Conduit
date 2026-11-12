//
//  InCallStatusTests.swift
//  ConduitTests
//
//  The in-call status-line copy mapping. `.connected` and `.idle` carry no static
//  text (the view shows a live timer / no surface). A held or interrupted call
//  shows that instead, and the hold control applies only to a call that is up.
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

    // MARK: - Held and paused

    @Test(arguments: [
        CallState.connecting, .connected(since: Date(timeIntervalSince1970: 0)), .reconnecting(attempt: 0),
    ])
    func holdWinsOverTheStateAndAnInterruption(state: CallState) {
        #expect(InCallStatus.pausedText(for: state, isOnHold: true, isInterrupted: false) == "On Hold")
        #expect(InCallStatus.pausedText(for: state, isOnHold: true, isInterrupted: true) == "On Hold")
    }

    @Test func anInterruptionWithoutHoldIsPaused() {
        let state = CallState.connected(since: Date(timeIntervalSince1970: 0))
        #expect(InCallStatus.pausedText(for: state, isOnHold: false, isInterrupted: true) == "Paused")
        #expect(InCallStatus.pausedText(for: state, isOnHold: false, isInterrupted: false) == nil)
    }

    @Test(arguments: [CallState.ended(.completed), .failed(.lostConnection)])
    func anEndedCallIsNeverShownHeld(state: CallState) {
        #expect(InCallStatus.pausedText(for: state, isOnHold: true, isInterrupted: true) == nil)
    }

    @Test(arguments: [
        (CallState.idle, false),
        (.incomingRinging, false),
        (.dialing, false),
        (.connecting, true),
        (.connected(since: Date(timeIntervalSince1970: 0)), true),
        (.reconnecting(attempt: 2), true),
        (.ended(.completed), false),
        (.failed(.agentUnreachable), false),
    ])
    func holdAppliesWhileTheCallIsUp(state: CallState, expected: Bool) {
        #expect(InCallStatus.canHold(state) == expected)
    }
}
