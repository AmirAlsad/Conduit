//
//  SmallWebRTCConnectionGateTests.swift
//  ConduitTests
//
//  The rules the SmallWebRTC adapter reports by: one `.connected` per attempt,
//  nothing that steers the engine once an attempt is over, a connect that finds
//  the session still up reporting it connected only when its agent is ready and
//  taking it over otherwise, signals only over an open data channel, and only the
//  newest of overlapping connects owning the transport.
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

    @Test func aJoinedAttemptWhoseAgentWasReportedReadyReportsConnected() {
        var gate = liveGate()
        _ = gate.transportDidBecomeReady() // bot-ready before the client's state says ready
        #expect(gate.plan(for: .awaitingBot) == .reportConnected)
    }

    @Test func aSessionWhoseBotNeverGotReadyIsTakenOver() {
        // The engine's join deadline ran out, or a hold paused that attempt: it comes
        // back with fresh credentials, which must not be refused or ignored.
        let gate = liveGate()
        #expect(gate.plan(for: .awaitingBot) == .takeOver)
    }

    @Test func aJoinStillInFlightIsTakenOver() {
        #expect(liveGate().plan(for: .negotiating) == .takeOver)
    }

    @Test func aSessionWhoseAttemptIsOverIsTakenOver() {
        var dropped = liveGate()
        _ = dropped.transportDidBecomeReady()
        _ = dropped.transportDidDisconnect()
        #expect(dropped.plan(for: .ready) == .takeOver)
        #expect(dropped.plan(for: .awaitingBot) == .takeOver)

        var botLeft = liveGate()
        _ = botLeft.transportDidBecomeReady()
        _ = botLeft.botDidLeave()
        #expect(botLeft.plan(for: .ready) == .takeOver) // the client is still in the call

        var failed = liveGate()
        failed.connectDidFail()
        #expect(failed.plan(for: .negotiating) == .takeOver)
    }

    @Test func aLeavingSessionIsTakenOver() {
        #expect(liveGate().plan(for: .leaving) == .takeOver)
    }

    @Test func aTakenOverSessionReportsNothingWhileTheNewAttemptDoes() {
        var old = liveGate()
        old.retire()
        var new = SmallWebRTCConnectionGate()
        new.connectDidStart()
        #expect(old.botDidLeave() == nil)
        #expect(old.transportDidDisconnect() == nil)
        #expect(new.transportDidBecomeReady() == .connected)
    }

    // MARK: - Call-control signals

    @Test(arguments: [SmallWebRTCSessionPhase.awaitingBot, .ready])
    func aLiveAttemptWithAnOpenDataChannelCarriesSignals(phase: SmallWebRTCSessionPhase) {
        #expect(liveGate().carriesSignals(in: phase))
    }

    @Test(arguments: [SmallWebRTCSessionPhase.idle, .negotiating, .leaving])
    func noDataChannelCarriesNoSignal(phase: SmallWebRTCSessionPhase) {
        #expect(!liveGate().carriesSignals(in: phase))
    }

    @Test func anAttemptThatIsOverCarriesNoSignal() {
        var botLeft = liveGate()
        _ = botLeft.transportDidBecomeReady()
        _ = botLeft.botDidLeave()
        #expect(!botLeft.carriesSignals(in: .ready))

        var dropped = liveGate()
        _ = dropped.transportDidDisconnect()
        #expect(!dropped.carriesSignals(in: .awaitingBot))

        var leaving = liveGate()
        leaving.userDidRequestDisconnect()
        #expect(!leaving.carriesSignals(in: .ready))

        var retired = liveGate()
        retired.retire()
        #expect(!retired.carriesSignals(in: .ready))
    }
}

/// Which of several overlapping connects owns the transport.
struct SmallWebRTCConnectLedgerTests {

    @Test func aLoneConnectOwnsTheTransport() {
        var ledger = SmallWebRTCConnectLedger()
        let ticket = ledger.connectDidBegin()
        #expect(ledger.standing(of: ticket) == .current)
    }

    @Test func ofTwoOverlappingConnectsOnlyTheNewerOwnsTheTransport() {
        var ledger = SmallWebRTCConnectLedger()
        let older = ledger.connectDidBegin()
        let newer = ledger.connectDidBegin()
        #expect(ledger.standing(of: older) == .superseded)
        #expect(ledger.standing(of: newer) == .current)
    }

    @Test func aDisconnectDuringAConnectLeavesItOwningNothing() {
        var ledger = SmallWebRTCConnectLedger()
        let joining = ledger.connectDidBegin()
        ledger.disconnectDidBegin()
        #expect(ledger.standing(of: joining) == .disconnected)
    }

    @Test func aConnectAfterADisconnectOwnsTheTransport() {
        var ledger = SmallWebRTCConnectLedger()
        let first = ledger.connectDidBegin()
        ledger.disconnectDidBegin()
        let second = ledger.connectDidBegin()
        #expect(ledger.standing(of: first) == .disconnected)
        #expect(ledger.standing(of: second) == .current)
    }
}
