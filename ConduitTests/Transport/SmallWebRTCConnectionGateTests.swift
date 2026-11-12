//
//  SmallWebRTCConnectionGateTests.swift
//  ConduitTests
//
//  The rules the SmallWebRTC adapter reports by: one `.connected` per attempt,
//  nothing that steers the engine once an attempt is over, and a connect that
//  finds the session still up never resetting what it will report.
//

import Testing
@testable import Conduit
import ConduitCallEngine

struct SmallWebRTCConnectionGateTests {

    private func liveGate() -> SmallWebRTCConnectionGate {
        var gate = SmallWebRTCConnectionGate()
        gate.connectDidStart()
        return gate
    }

    @Test func reportsConnectedOncePerAttempt() {
        var gate = liveGate()
        #expect(gate.transportDidBecomeReady() == .connected)
        #expect(gate.transportDidBecomeReady() == nil) // bot-ready after client-ready

        gate.connectDidStart()
        #expect(gate.transportDidBecomeReady() == .connected)
    }

    @Test func aDropIsReportedOnceAndEndsTheAttempt() {
        var gate = liveGate()
        _ = gate.transportDidBecomeReady()
        #expect(gate.transportDidDisconnect() == .disconnected(reason: .networkDropped))
        #expect(gate.transportDidDisconnect() == nil)
        #expect(gate.botDidLeave() == nil) // a late bot-left must not end a reconnecting call
        #expect(gate.transportDidBecomeReady() == nil)
        #expect(!gate.isLive)
    }

    @Test func aThrownConnectIsNotAlsoReportedAsADrop() {
        var gate = liveGate()
        gate.connectDidFail()
        #expect(gate.transportDidDisconnect() == nil) // the client's own disconnect after the throw
        #expect(!gate.isLive)
    }

    @Test func theHostsDisconnectReportsOnlyRequestedByUser() {
        var gate = liveGate()
        _ = gate.transportDidBecomeReady()
        gate.userDidRequestDisconnect()
        #expect(gate.botDidLeave() == nil)
        #expect(gate.transportDidDisconnect() == .disconnected(reason: .requestedByUser))
    }

    @Test func theBotLeavingBeforeReadyEndsTheCall() {
        var gate = liveGate()
        #expect(gate.botDidLeave() == .disconnected(reason: .botLeft))
        #expect(gate.transportDidDisconnect() == nil)
    }

    @Test func aRetiredSessionReportsNothing() {
        var gate = liveGate()
        gate.retire()
        #expect(gate.transportDidBecomeReady() == nil)
        #expect(gate.transportDidDisconnect() == nil)
        #expect(gate.botDidLeave() == nil)
        #expect(gate.reconfirmConnected() == nil)
    }

    // MARK: - A connect that finds the session up

    @Test func anIdleSessionJoins() {
        #expect(SmallWebRTCConnectionGate().plan(for: .idle) == .join)
        var over = liveGate()
        _ = over.transportDidDisconnect()
        #expect(over.plan(for: .idle) == .join)
    }

    @Test func aReadyLiveAttemptReportsConnectedWithoutReset() {
        var gate = liveGate()
        _ = gate.transportDidBecomeReady()
        #expect(gate.plan(for: .ready) == .reportConnected)
        #expect(gate.reconfirmConnected() == .connected)
        // Still the same attempt: a drop is still reported, once.
        #expect(gate.transportDidDisconnect() == .disconnected(reason: .networkDropped))
    }

    @Test func aJoinUnderWayIsLeftToFinish() {
        var gate = liveGate()
        #expect(gate.plan(for: .joining) == .awaitJoinUnderWay)
        #expect(gate.transportDidBecomeReady() == .connected) // the join still reports
    }

    @Test func aSessionWhoseAttemptIsOverIsReplaced() {
        var dropped = liveGate()
        _ = dropped.transportDidDisconnect()
        #expect(dropped.plan(for: .ready) == .replaceSession)
        #expect(dropped.plan(for: .joining) == .replaceSession)

        var failed = liveGate()
        failed.connectDidFail()
        #expect(failed.plan(for: .joining) == .replaceSession)
    }

    @Test func aLeavingSessionIsReplaced() {
        #expect(liveGate().plan(for: .leaving) == .replaceSession)
    }
}
