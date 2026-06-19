//
//  CallSessionCoordinatorTests.swift
//  ConduitTests
//
//  The call state machine — the heart of the app and the most-tested unit. Every
//  row of the transition table is asserted here against fakes, at simulator speed.
//

import Foundation
import Testing
@testable import Conduit

@MainActor
struct CallSessionCoordinatorTests {

    // MARK: - Placing a call

    @Test func placeCallReportsToCallKitAndConnectsTransport() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)

        #expect(h.coordinator.state.isConnecting)
        #expect(h.provider.startedCalls == [h.callID])
        #expect(h.provider.startedHandles == [h.agent.callHandle])
        #expect(h.provider.reportedConnecting == [h.callID])
        #expect(h.transport.connectCount == 1)
        #expect(h.transport.lastConfig?.token == "valid-token")
        #expect(h.transport.lastConfig?.kind == .daily)
        #expect(h.announcer.startedRepeating == [.connecting])
        // Donated so Siri's calling domain learns "this contact calls via Conduit".
        #expect(h.interactionDonor.donatedAgentIDs == [h.agent.id])
    }

    @Test func placeCallIgnoredWhenNotIdle() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        await h.coordinator.placeCall(h.agent)

        #expect(h.transport.connectCount == 1)
        #expect(h.provider.startedCalls == [h.callID])
    }

    @Test func connectedTransitionsAndReportsConnected() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        #expect(h.coordinator.state.isConnected)
        #expect(h.provider.reportedConnected == [h.callID])
        #expect(h.announcer.announced == [.connected])
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.stopRepeatingCount == 1)
    }

    // MARK: - Failures

    @Test func missingTokenFailsWithBadToken() async throws {
        let h = try CoordinatorHarness(token: nil)
        await h.coordinator.placeCall(h.agent)

        #expect(h.coordinator.state.failureReason == .badToken)
        #expect(h.transport.connectCount == 0)
        #expect(h.provider.reportedEnded.map(\.id) == [h.callID])
        #expect(h.provider.reportedEnded.first?.reason == .failed)
        let entries = try h.loggedEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.outcome == .failed)
        #expect(entries.first?.failureReason == .badToken)
    }

    @Test func connectThrowingFailsWithTransportError() async throws {
        let h = try CoordinatorHarness()
        h.transport.connectError = .connectionFailed("boom")
        await h.coordinator.placeCall(h.agent)

        #expect(h.coordinator.state.failureReason == .transportError)
        #expect(h.provider.reportedEnded.first?.reason == .failed)
        let entries = try h.loggedEntries()
        #expect(entries.first?.outcome == .failed)
        #expect(entries.first?.failureReason == .transportError)
    }

    @Test func startOutgoingCallThrowingFailsWithUnknown() async throws {
        let h = try CoordinatorHarness()
        h.provider.startError = TransportError.connectionFailed("callkit refused")
        await h.coordinator.placeCall(h.agent)

        #expect(h.coordinator.state.failureReason == .unknown)
        #expect(h.transport.connectCount == 0)
    }

    @Test func authFailureWhileConnectingFailsWithBadToken() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.disconnected(reason: .authFailed))

        #expect(h.coordinator.state.failureReason == .badToken)
    }

    @Test func transportAuthErrorWhileConnectingFailsWithBadToken() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.error(.authenticationFailed))

        #expect(h.coordinator.state.failureReason == .badToken)
    }

    // MARK: - Reconnection

    @Test func networkDropSchedulesReconnectAndRecovers() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.coordinator.handle(.disconnected(reason: .networkDropped))
        #expect(h.coordinator.state.reconnectingAttempt == 1)
        #expect(h.announcer.announced.contains(.disconnected))
        #expect(h.announcer.startedRepeating.contains(.retrying))

        await h.coordinator.awaitPendingReconnect()
        #expect(h.transport.connectCount == 2) // initial + one retry

        h.coordinator.handle(.connected)
        #expect(h.coordinator.state.isConnected)
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.announced.filter { $0 == .connected }.count == 2)
    }

    @Test func reconnectionBudgetExhaustionFailsWithLostConnection() async throws {
        let policy = ReconnectionPolicy(maxAttempts: 2, baseDelaySeconds: 0, maxDelaySeconds: 0)
        let h = try CoordinatorHarness(policy: policy)
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        // Two drops are absorbed as retries; the third exhausts the budget.
        h.coordinator.handle(.disconnected(reason: .networkDropped))
        await h.coordinator.awaitPendingReconnect()
        #expect(h.coordinator.state.reconnectingAttempt == 1)

        h.coordinator.handle(.disconnected(reason: .networkDropped))
        await h.coordinator.awaitPendingReconnect()
        #expect(h.coordinator.state.reconnectingAttempt == 2)

        h.coordinator.handle(.disconnected(reason: .networkDropped))
        #expect(h.coordinator.state.failureReason == .lostConnection)
        #expect(h.provider.reportedEnded.first?.reason == .failed)
        #expect(h.transport.connectCount == 3) // initial + two retries
    }

    // MARK: - Audio-session handshake (the ownership invariant)

    @Test func activationAttachesMediaAndEnablesMic() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        let session = FakeAudioSession(hasExternalAudioRoute: false)
        await h.coordinator.activate(session)

        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
    }

    @Test func handsFreeDefaultRoutesToSpeakerWithoutExternalRoute() async throws {
        let h = try CoordinatorHarness() // FakeTransport routes: speaker + receiver (no external)
        await h.transport.setAudioDevice("receiver") // start on the earpiece
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        await waitUntil { h.transport.selectedAudioDeviceID == "speaker" }
        #expect(h.transport.selectedAudioDeviceID == "speaker")
    }

    @Test func handsFreeDefaultLeavesExternalRouteAlone() async throws {
        let h = try CoordinatorHarness()
        h.transport.fakeAudioDevices = [
            AudioDeviceInfo(id: "bluetooth", name: "Bluetooth Speaker & Mic"),
            AudioDeviceInfo(id: "speaker", name: "Built-in Speaker & Mic"),
            AudioDeviceInfo(id: "earpiece", name: "Built-in Earpiece & Mic"),
        ]
        await h.transport.setAudioDevice("bluetooth") // on AirPods
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        await waitUntil { h.coordinator.audioDevices.contains { $0.id == "bluetooth" } }
        #expect(h.transport.selectedAudioDeviceID == "bluetooth") // didn't yank to speaker
    }

    @Test func pushToTalkKeepsMicOffOnActivation() async throws {
        let h = try CoordinatorHarness(pushToTalk: true)
        await h.coordinator.placeCall(h.agent)

        let session = FakeAudioSession(hasExternalAudioRoute: false)
        await h.coordinator.activate(session)

        #expect(h.transport.isAudioAttached)
        #expect(!h.transport.isMicEnabled)
    }

    // MARK: - Mute

    @Test func inAppMuteReflectsToTransportAndProvider() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        await h.coordinator.setMuted(true)

        #expect(h.coordinator.isMuted)
        #expect(!h.transport.isMicEnabled)
        #expect(h.provider.muteStates[h.callID] == true)
    }

    @Test func systemMuteDoesNotCallBackIntoProvider() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.coordinator.providerPerformSetMuted(h.callID, muted: true)

        #expect(h.coordinator.isMuted)
        #expect(h.provider.muteStates[h.callID] == nil)
    }

    // MARK: - Ending

    @Test func inAppEndDisconnectsRequestsEndAndLogsCompleted() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        await h.coordinator.endCall()

        #expect(h.coordinator.state.endedOutcome == .completed)
        #expect(h.provider.endRequests == [h.callID])
        #expect(h.provider.reportedEnded.isEmpty) // requested via endCall; not double-reported
        let entries = try h.loggedEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.outcome == .completed)
    }

    @Test func systemEndLogsAndDoesNotRequestEndAgain() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.coordinator.providerPerformEndCall(h.callID)

        #expect(h.coordinator.state.endedOutcome == .completed)
        #expect(h.provider.endRequests.isEmpty)
        let entries = try h.loggedEntries()
        #expect(entries.first?.outcome == .completed)
    }

    @Test func endBeforeConnectLogsCanceled() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)

        await h.coordinator.endCall()

        #expect(h.coordinator.state.endedOutcome == .canceled)
        let entries = try h.loggedEntries()
        #expect(entries.first?.outcome == .canceled)
    }

    @Test func botLeftEndsCallAsRemote() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.coordinator.handle(.disconnected(reason: .botLeft))

        #expect(h.coordinator.state.endedOutcome == .completed)
        #expect(h.provider.reportedEnded.first?.reason == .remoteEnded)
    }

    @Test func callLogRecordsConnectedDuration() async throws {
        let clock = MutableClock()
        let h = try CoordinatorHarness(now: clock.now)
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected) // firstConnectedAt = t0
        clock.advance(60)
        await h.coordinator.endCall()

        let entries = try h.loggedEntries()
        #expect(entries.first?.duration == 60)
    }

    // MARK: - Lifecycle

    @Test func providerResetReturnsToIdle() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.coordinator.providerWasReset()

        #expect(h.coordinator.state == .idle)
        #expect(h.coordinator.activeAgent == nil)
    }

    @Test func resetReturnsToIdleAfterTerminalState() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)
        await h.coordinator.endCall()

        h.coordinator.reset()

        #expect(h.coordinator.state == .idle)
        #expect(h.coordinator.activeAgent == nil)
    }

    @Test func lateConnectFailureAfterResetDoesNotReFail() async throws {
        let h = try CoordinatorHarness()
        h.transport.suspendConnect = true
        h.transport.connectError = .authenticationFailed

        // placeCall → connectTransport → connect() is entered and suspends.
        let place = Task { await h.coordinator.placeCall(h.agent) }
        await waitUntil { h.transport.connectCount == 1 }

        // An event fails the call (as the real transport would), then the user closes it.
        h.coordinator.handle(.disconnected(reason: .authFailed))
        #expect(h.coordinator.state.failureReason == .badToken)
        h.coordinator.reset()
        #expect(h.coordinator.state == .idle)

        // connect() now resolves LATE and throws. The stale failure must be ignored —
        // re-failing would re-present the call screen after it was dismissed.
        h.transport.releaseConnect()
        await place.value

        #expect(h.coordinator.state == .idle)
    }

    // MARK: - Speaking indicators

    @Test func botSpeakingEventsTrackState() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.coordinator.handle(.botStartedSpeaking)
        #expect(h.coordinator.isBotSpeaking)

        h.coordinator.handle(.botStoppedSpeaking)
        #expect(!h.coordinator.isBotSpeaking)
    }

    @Test func remoteAudioLevelUpdates() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.remoteAudioLevel(0.7))

        #expect(h.coordinator.remoteAudioLevel == 0.7)
    }

    // MARK: - Real delegate / stream paths (the fire-and-forget seams)

    @Test func activationViaSystemDelegateAttachesMedia() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        let session = FakeAudioSession(hasExternalAudioRoute: false)
        h.provider.simulateActivate(session) // the real CallKit delegate path
        await h.coordinator.awaitPendingActivation()

        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
    }

    @Test func micReappliedOnConnectWhenActivationCameFirst() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)

        // CallKit activates the session BEFORE the transport reports connected —
        // the race a slow pairing fetch exposes. The one-shot enable in activate()
        // can't turn on a not-yet-joined mic, so the coordinator must re-apply it
        // once connected. (The fake doesn't model the no-op, so we assert the
        // re-apply happens, not the device-only end state.)
        let session = FakeAudioSession(hasExternalAudioRoute: false)
        h.provider.simulateActivate(session)
        await h.coordinator.awaitPendingActivation()
        #expect(h.coordinator.isAudioActivated)
        let callsBeforeConnect = h.transport.setMicEnabledCallCount

        h.transport.emit(.connected)
        await waitUntil { h.transport.setMicEnabledCallCount > callsBeforeConnect }
        #expect(h.transport.setMicEnabledCallCount > callsBeforeConnect)
        #expect(h.transport.isMicEnabled)
    }

    @Test func transportEventsReachCoordinatorViaStream() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)

        h.transport.emit(.connected) // delivered through the AsyncStream, not handle()
        await waitUntil { h.coordinator.state.isConnected }

        #expect(h.coordinator.state.isConnected)
        #expect(h.provider.reportedConnected == [h.callID])
    }

    // MARK: - Additional transition-table coverage

    @Test func transportSelfHealReconnectingIsDisplayOnly() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.coordinator.handle(.reconnecting)
        #expect(h.coordinator.state.reconnectingAttempt == 0) // no app attempt counted
        #expect(h.announcer.announced.contains(.disconnected))
        #expect(h.announcer.startedRepeating.contains(.retrying))

        h.coordinator.handle(.connected)
        #expect(h.coordinator.state.isConnected)
    }

    @Test func errorWhileConnectedIsNonTerminal() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.coordinator.handle(.error(.timedOut))
        #expect(h.coordinator.state.isConnected)
    }

    @Test func unknownDisconnectWhileConnectedReconnects() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.coordinator.handle(.disconnected(reason: .unknown))
        #expect(h.coordinator.state.reconnectingAttempt == 1)
        await h.coordinator.awaitPendingReconnect()
        #expect(h.transport.connectCount == 2)
    }

    @Test func disconnectBeforeEverConnectingFails() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent) // connecting, never connected

        h.coordinator.handle(.disconnected(reason: .networkDropped))
        #expect(h.coordinator.state.failureReason == .transportError)
    }

    @Test func requestedByUserDisconnectIsNoOp() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        h.coordinator.handle(.disconnected(reason: .requestedByUser))
        #expect(h.coordinator.state.isConnected)
    }

    @Test func endWhileReconnectingCancelsReconnect() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)
        h.coordinator.handle(.disconnected(reason: .networkDropped))
        await h.coordinator.awaitPendingReconnect()
        #expect(h.coordinator.state.reconnectingAttempt == 1)

        await h.coordinator.endCall()

        #expect(h.coordinator.state.endedOutcome == .completed)
        #expect(h.coordinator.reconnectTask == nil)
    }

    @Test func duplicateConnectedIsIgnored() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)
        h.coordinator.handle(.connected) // stray duplicate

        #expect(h.provider.reportedConnected == [h.callID])
        #expect(h.announcer.announced.filter { $0 == .connected }.count == 1)
    }

    @Test func callCanBeReplacedAfterReset() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)
        await h.coordinator.endCall()
        h.coordinator.reset()
        #expect(h.coordinator.state == .idle)

        await h.coordinator.placeCall(h.agent)
        h.coordinator.handle(.connected)

        #expect(h.coordinator.state.isConnected)
        #expect(!h.coordinator.isMuted)
        #expect(h.transport.connectCount == 2)
    }
}
