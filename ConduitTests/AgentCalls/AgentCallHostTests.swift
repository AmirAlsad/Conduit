//
//  AgentCallHostTests.swift
//  ConduitTests
//
//  Conduit's side of the call engine, driven by the real engine against
//  fakes: the call-log rows it writes from each record, the engine's cues it
//  speaks, what a phone call does to a call, Siri donation, missed-call
//  notifications, the receipt bearer, the agent targets it hands the engine
//  (direct, pairing, inline push, and the ring preparation it allows), and VoIP
//  token registration.
//

import Foundation
import Testing
@testable import Conduit
import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct AgentCallHostTests {

    private let endpoint = URL(string: "https://engine.example.com/connect/live")!
    private let statusEndpoint = URL(string: "https://engine.example.com/inbound/status/live")!

    // MARK: - History rows

    @Test func completedCallWritesHistoryRow() async throws {
        let clock = MutableClock()
        let h = try AgentCallHostHarness(now: clock.now)
        await h.placeCall()
        h.system.deliverTransportEvent(.connected)
        clock.advance(60)
        await h.engine.endCall()

        let entries = try h.loggedEntries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.agent?.id == h.agent.id)
        #expect(entry.direction == .outgoing)
        #expect(entry.outcome == .completed)
        #expect(entry.duration == 60)
        #expect(entry.startedAt == Date(timeIntervalSince1970: 1_000_000))
        #expect(entry.transportKind == .daily)
        #expect(entry.failureReason == nil)
    }

    @Test func missingTokenWritesFailedBadTokenRow() async throws {
        let h = try AgentCallHostHarness(token: nil)
        await h.placeCall()

        #expect(h.engine.state.failureReason == .badToken)
        #expect(h.transport.connectCount == 0)
        let entries = try h.loggedEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.outcome == .failed)
        #expect(entries.first?.failureReason == .badToken)
    }

    @Test func transportFailureWritesFailedTransportErrorRow() async throws {
        let h = try AgentCallHostHarness()
        h.transport.connectError = .connectionFailed("boom")
        await h.placeCall()

        let entries = try h.loggedEntries()
        #expect(entries.first?.outcome == .failed)
        #expect(entries.first?.failureReason == .transportError)
    }

    @Test func endBeforeConnectWritesCanceledRow() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        await h.engine.endCall()

        #expect(try h.loggedEntries().map(\.outcome) == [.canceled])
    }

    @Test func systemEndWritesOneCompletedRow() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        h.system.deliverTransportEvent(.connected)
        h.system.endCallFromSystem(try #require(h.system.startedCallIDs.first))

        #expect(try h.loggedEntries().map(\.outcome) == [.completed])
    }

    @Test func answeredCallWritesIncomingRow() async throws {
        let h = try AgentCallHostHarness()
        h.ring()
        await h.system.answerIncomingCall()
        h.system.deliverTransportEvent(.connected)
        await h.engine.endCall()

        let entry = try #require(try h.loggedEntries().first)
        #expect(entry.direction == .incoming)
        #expect(entry.outcome == .completed)
        #expect(entry.failureReason == nil)
        #expect(h.missedNotifier.missedAgentNames.isEmpty)
    }

    @Test func declinedRingWritesDeclinedRowWithoutNotification() async throws {
        let h = try AgentCallHostHarness()
        let callID = UUID()
        h.ring(callID: callID)
        h.system.endCallFromSystem(callID)

        let entry = try #require(try h.loggedEntries().first)
        #expect(entry.direction == .incoming)
        #expect(entry.outcome == .declined)
        #expect(h.missedNotifier.missedAgentNames.isEmpty)
    }

    @Test func unknownTargetWritesNoRow() async throws {
        let h = try AgentCallHostHarness()
        h.ring(agentID: UUID())

        #expect(h.engine.state == .idle) // the ring ends without a failure screen
        #expect(try h.loggedEntries().isEmpty) // no agent to attribute the row to
        #expect(h.missedNotifier.missedAgentNames.isEmpty)

        h.host.callEngine(h.engine, didFinish: CallRecord(
            targetID: UUID(), direction: .incoming, startedAt: .now, duration: 0,
            outcome: .noAnswer, missedReason: .busy
        ))
        #expect(try h.loggedEntries().isEmpty)
        #expect(h.missedNotifier.missedAgentNames.isEmpty)
    }

    @Test func busyRingWritesMissedRowAndNotifies() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall() // already in a call
        h.ring()

        let entries = try h.loggedEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.direction == .incoming)
        #expect(entries.first?.outcome == .noAnswer)
        #expect(entries.first?.duration == 0)
        #expect(entries.first?.transportKind == .daily)
        #expect(entries.first?.missedReason == .busy)
        #expect(h.missedNotifier.missedAgentNames == [h.agent.name])
        #expect(h.missedNotifier.missedReasons == [.busy])
        // Rang under the push's fallbacks, corrected to the agent before it ended.
        #expect(h.system.updatedCalls.first?.handle == h.agent.syntheticEmail)
        #expect(h.system.updatedCalls.first?.displayName == h.agent.name)
    }

    @Test func focusFilteredRingWritesMissedRowAndNotifies() async throws {
        let h = try AgentCallHostHarness()
        h.system.incomingReportResult = .filteredByFocus
        h.ring()

        #expect(h.engine.state == .idle)
        let entries = try h.loggedEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.direction == .incoming)
        #expect(entries.first?.outcome == .noAnswer)
        #expect(entries.first?.missedReason == .filteredByFocus)
        #expect(h.missedNotifier.missedAgentNames == [h.agent.name])
        #expect(h.missedNotifier.missedReasons == [.filteredByFocus])
    }

    @Test func ringThatRingsOutWritesMissedRowAndNotifies() async throws {
        let h = try AgentCallHostHarness(ringTimeout: .seconds(60), sleep: AgentCallHostHarness.parkedSleep)
        h.ring()
        #expect(h.engine.state == .incomingRinging)

        #expect(h.system.fireTimer(.ringTimeout))
        await h.system.awaitPendingWork()

        #expect(h.engine.state == .idle)
        let entry = try #require(try h.loggedEntries().first)
        #expect(entry.direction == .incoming)
        #expect(entry.outcome == .noAnswer)
        #expect(entry.missedReason == .ringTimedOut)
        #expect(h.missedNotifier.missedAgentNames == [h.agent.name])
        #expect(h.missedNotifier.missedReasons == [.ringTimedOut])
        #expect(h.announcer.startedRepeating.isEmpty) // CallKit's ringtone is the only sound
    }

    @Test func ringTheCallerCancelsWritesMissedRowAndNotifies() async throws {
        let h = try AgentCallHostHarness()
        let callID = UUID()
        h.ring(callID: callID)
        h.system.deliverPush(["action": "cancel", "call_id": callID.uuidString]) {}

        #expect(h.engine.state == .idle)
        let entry = try #require(try h.loggedEntries().first)
        #expect(entry.direction == .incoming)
        #expect(entry.outcome == .noAnswer)
        #expect(entry.missedReason == .canceledByCaller)
        #expect(h.missedNotifier.missedReasons == [.canceledByCaller])
        #expect(h.announcer.startedRepeating.isEmpty)
    }

    @Test func answeredAndDeclinedRowsCarryNoMissedReason() async throws {
        let h = try AgentCallHostHarness()
        let declined = UUID()
        h.ring(callID: declined)
        h.system.endCallFromSystem(declined)
        h.engine.reset()
        h.ring()
        await h.system.answerIncomingCall()
        h.system.deliverTransportEvent(.connected)
        await h.engine.endCall()

        let entries = try h.loggedEntries()
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.missedReason == nil })
    }

    @Test func remoteEndBeforeConnectWritesNoAnswerWithoutNotification() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        h.system.deliverTransportEvent(.disconnected(reason: .botLeft))

        #expect(h.engine.state.endedOutcome == .noAnswer) // state and row now agree
        #expect(try h.loggedEntries().map(\.outcome) == [.noAnswer])
        #expect(try h.loggedEntries().first?.missedReason == nil)
        #expect(h.missedNotifier.missedAgentNames.isEmpty) // not a missed ring
    }

    @Test func rowRecordsTheAgentsTransportKind() async throws {
        let h = try AgentCallHostHarness(transportKind: .livekit)
        await h.placeCall()
        await h.engine.endCall()

        #expect(try h.loggedEntries().first?.transportKind == .livekit)
    }

    // MARK: - Spoken cues

    @Test func outgoingCallCuesConnectingThenConnected() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        #expect(h.announcer.startedRepeating == [.connecting])
        #expect(h.announcer.repeatingPhrase == .connecting)

        await agentIsReady(h)
        #expect(h.announcer.announced == [.connected])
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.stopRepeatingCount == 1)
    }

    @Test func connectedBeforeActivationIsAnnouncedAtTheActivation() async throws {
        let h = try soundsHarness()
        await h.placeCall()

        await agentIsReady(h)
        guard case .connected = h.engine.state else {
            Issue.record("Expected connected, got \(h.engine.state)")
            return
        }
        #expect(h.announcer.announced.isEmpty) // CallKit has not activated the audio yet
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.stopRepeatingCount == 1)

        await h.system.activateAudioSession()
        #expect(h.announcer.announced == [.connected])
        #expect(h.announcer.stopRepeatingCount == 1)
    }

    @Test func dropAndRecoveryCuesDisconnectedOnceThenConnected() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        h.system.deliverTransportEvent(.connected)

        h.system.deliverTransportEvent(.disconnected(reason: .networkDropped))
        #expect(h.announcer.announced.contains(.disconnected))
        #expect(h.announcer.startedRepeating.contains(.retrying))
        await h.system.awaitPendingReconnect()

        h.system.deliverTransportEvent(.disconnected(reason: .networkDropped)) // attempt 2: no new cue
        await h.system.awaitPendingReconnect()

        h.system.deliverTransportEvent(.connected)
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.announced == [.connected, .disconnected, .connected])
        #expect(h.announcer.startedRepeating == [.connecting, .retrying])
    }

    @Test func selfHealThatEscalatesAnnouncesDisconnectedOnce() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        h.system.deliverTransportEvent(.connected)

        h.system.deliverTransportEvent(.reconnecting) // the transport self-heals (display only)
        #expect(h.announcer.announced == [.connected, .disconnected])
        #expect(h.announcer.repeatingPhrase == .retrying)

        h.system.deliverTransportEvent(.disconnected(reason: .networkDropped)) // then drops for real
        await h.system.awaitPendingReconnect()
        #expect(h.engine.state == .reconnecting(attempt: 1))
        #expect(h.announcer.announced == [.connected, .disconnected]) // one outage, one cue
        #expect(h.announcer.repeatingPhrase == .retrying)

        h.system.deliverTransportEvent(.connected)
        #expect(h.announcer.announced == [.connected, .disconnected, .connected])
        #expect(h.announcer.repeatingPhrase == nil)
    }

    @Test func duplicateConnectedAnnouncesOnce() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        h.system.deliverTransportEvent(.connected)
        h.system.deliverTransportEvent(.connected)

        #expect(h.announcer.announced.filter { $0 == .connected }.count == 1)
    }

    @Test func terminalTransitionsStopTheRepeatingCue() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        #expect(h.announcer.repeatingPhrase == .connecting)

        await h.engine.endCall()
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.stopRepeatingCount == 1)
    }

    @Test func providerResetStopsTheRingbackAndWritesAFailedRow() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        #expect(h.announcer.repeatingPhrase == .connecting)

        h.system.resetProvider()

        #expect(h.engine.state.failureReason == .unknown)
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.stopRepeatingCount == 1)
        let entry = try #require(try h.loggedEntries().first)
        #expect(entry.outcome == .failed)
        #expect(entry.failureReason == .unknown)
    }

    @Test func providerResetStopsTheRetryingLoop() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        h.system.deliverTransportEvent(.connected)
        h.system.deliverTransportEvent(.reconnecting)
        #expect(h.announcer.repeatingPhrase == .retrying)

        h.system.resetProvider()

        #expect(h.engine.state.failureReason == .unknown)
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(try h.loggedEntries().map(\.outcome) == [.failed])
    }

    @Test func connectingStopsTheRingbackAndAnEndedCallSilencesEverything() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        #expect(h.announcer.repeatingPhrase == .connecting)

        h.system.deliverTransportEvent(.connected)
        await h.system.activateAudioSession()
        await h.system.awaitPendingWork()
        #expect(h.announcer.stopRepeatingCount == 1)
        #expect(h.announcer.stopNowCount == 0)

        await h.engine.endCall()
        #expect(h.announcer.stopNowCount >= 1)
    }

    @Test func hangingUpWhileStillRingingSilencesTheRingbackAtOnce() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        #expect(h.announcer.repeatingPhrase == .connecting)

        await h.engine.endCall()

        #expect(h.announcer.stopNowCount >= 1)
        #expect(h.announcer.repeatingPhrase == nil)
    }

    @Test func providerResetWhileRingingIsSilentAndRecordedAsFailed() async throws {
        let h = try AgentCallHostHarness()
        h.ring()

        h.system.resetProvider()

        #expect(h.engine.state == .idle)
        #expect(h.announcer.startedRepeating.isEmpty)
        #expect(h.announcer.stopRepeatingCount == 0)
        let entry = try #require(try h.loggedEntries().first)
        #expect(entry.direction == .incoming)
        #expect(entry.outcome == .failed)
        #expect(entry.missedReason == nil)
        #expect(h.missedNotifier.missedAgentNames.isEmpty)
    }

    // MARK: - Siri donation

    @Test func outgoingCallDonatesOnce() async throws {
        let h = try AgentCallHostHarness()
        h.system.suspendsOutgoingStarts = true
        h.transport.suspendConnect = true // the transport this call will get

        // A poll, not awaitPendingWork: the engine is blocked inside the held start,
        // work the test's own Task began, which the package cannot wait for.
        let place = Task { await h.placeCall() }
        await waitUntil { h.system.pendingOutgoingStartCount == 1 }
        #expect(h.system.pendingOutgoingStartCount == 1)
        #expect(h.interactionDonor.donatedAgentIDs.isEmpty) // not while dialing

        h.system.releaseOutgoingStarts()
        await waitUntil { h.transport.connectCount == 1 }
        #expect(h.engine.state.isConnecting)
        #expect(h.interactionDonor.donatedAgentIDs == [h.agent.id]) // on dialing → connecting

        h.transport.releaseConnect()
        await place.value
        h.system.deliverTransportEvent(.connected)
        await h.engine.endCall()
        #expect(h.interactionDonor.donatedAgentIDs == [h.agent.id])
    }

    @Test func donationHappensEvenIfTheConnectFails() async throws {
        let h = try AgentCallHostHarness(token: nil)
        await h.placeCall()

        #expect(h.engine.state.failureReason == .badToken)
        #expect(h.interactionDonor.donatedAgentIDs == [h.agent.id])
    }

    @Test func anAnswerConnectsWithoutARingbackOrADonation() async throws {
        let h = try AgentCallHostHarness()
        h.ring()
        await h.system.answerIncomingCall()

        #expect(h.engine.state.isConnecting)
        #expect(h.announcer.startedRepeating.isEmpty)
        #expect(h.interactionDonor.donatedAgentIDs.isEmpty)
    }

    // MARK: - Receipt bearer

    @Test func bearerIsTheAgentsAPIKey() async throws {
        let h = try AgentCallHostHarness()
        #expect(h.host.callEngine(h.engine, ringStatusBearerForTarget: h.agent.id) == nil) // none stored

        try h.keychain.setToken("agent-api-key", for: KeychainTokenRef(account: h.agent.keychainTokenRef))
        #expect(h.host.callEngine(h.engine, ringStatusBearerForTarget: h.agent.id) == "agent-api-key")
        #expect(h.host.callEngine(h.engine, ringStatusBearerForTarget: UUID()) == nil)
    }

    @Test func answerReportsAnsweredReceiptWithBearer() async throws {
        let h = try AgentCallHostHarness()
        try h.keychain.setToken("agent-api-key", for: KeychainTokenRef(account: h.agent.keychainTokenRef))
        let callID = UUID()
        h.ring(callID: callID, statusURL: statusEndpoint)
        await h.system.answerIncomingCall()

        let receipt = try #require(h.system.ringReceipts.first)
        #expect(h.system.ringReceipts.count == 1)
        #expect(receipt.status == "answered")
        #expect(receipt.callID == callID)
        #expect(receipt.endpoint == statusEndpoint)
        #expect(receipt.bearer == "agent-api-key")
    }

    // MARK: - Incoming targets

    @Test func receiveCallRingsAndResolvesAgent() async throws {
        let h = try AgentCallHostHarness()
        let callID = UUID()
        h.ring(callID: callID)

        #expect(h.engine.state == .incomingRinging)
        #expect(h.engine.activeCall?.targetID == h.agent.id)
        #expect(h.engine.activeCall?.displayName == h.agent.name)
        #expect(h.system.reportedIncomingCalls.map(\.id) == [callID])
        #expect(h.system.updatedCalls.first?.handle == h.agent.syntheticEmail)
    }

    @Test func ringWithoutIdentityIsCorrectedToTheAgent() async throws {
        let h = try AgentCallHostHarness()
        let callID = UUID()
        h.ring(callID: callID) // no display_name, no handle

        let reported = try #require(h.system.reportedIncomingCalls.first)
        #expect(reported.displayName == "Agent")
        #expect(reported.handle == CallTarget.defaultHandle(for: h.agent.id))
        let corrected = try #require(h.system.updatedCalls.first)
        #expect(corrected.id == callID)
        #expect(corrected.displayName == h.agent.name)
        #expect(corrected.handle == h.agent.syntheticEmail)
        #expect(h.system.updatedCalls.count == 1)
    }

    @Test func ringUnderTheAgentsOwnIdentityIsNotCorrected() async throws {
        let h = try AgentCallHostHarness()
        h.ring(displayName: h.agent.name, handle: h.agent.syntheticEmail)

        #expect(h.system.reportedIncomingCalls.first?.handle == h.agent.syntheticEmail)
        #expect(h.system.updatedCalls.isEmpty)
        #expect(h.engine.state == .incomingRinging)
    }

    @Test func answerConnectsViaAgentDirectConfig() async throws {
        let h = try AgentCallHostHarness()
        h.ring()
        await h.system.answerIncomingCall()

        #expect(h.transport.connectCount == 1)
        #expect(h.transport.lastConnection?.token == "valid-token")
        #expect(h.transport.lastConnection?.url == h.agent.connectionURL)
        #expect(h.engine.state.isConnecting)
    }

    @Test func answerWithInlineCredentialsJoinsDirectly() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint) // inline wins over pairing
        let room = URL(string: "https://example.daily.co/inbound-room")!
        h.ring(roomURL: room, token: "push-token")
        await h.system.answerIncomingCall()

        #expect(h.transport.lastConnection?.url == room)
        #expect(h.transport.lastConnection?.token == "push-token")
        #expect(h.pairing.requests.isEmpty)
    }

    @Test func directCredentialsRepeatOnEveryAttempt() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        h.system.deliverTransportEvent(.connected)
        let first = try #require(h.transport.lastConnection)
        #expect(first == CallConnection(url: try #require(h.agent.connectionURL), token: "valid-token"))

        h.system.deliverTransportEvent(.disconnected(reason: .networkDropped))
        await h.system.awaitPendingReconnect()

        #expect(h.transport.connectCount == 2)
        #expect(h.transport.lastConnection == first)
        #expect(h.pairing.requests.isEmpty)
    }

    @Test func inlinePushCredentialsRepeatOnEveryAttempt() async throws {
        let h = try AgentCallHostHarness()
        let room = URL(string: "https://example.daily.co/inbound-room")!
        h.ring(roomURL: room, token: "push-token")
        await h.system.answerIncomingCall()
        h.system.deliverTransportEvent(.connected)

        h.system.deliverTransportEvent(.disconnected(reason: .networkDropped))
        await h.system.awaitPendingReconnect()

        #expect(h.transport.connectCount == 2)
        #expect(h.transport.lastConnection == CallConnection(url: room, token: "push-token"))
        #expect(h.pairing.requests.isEmpty)
    }

    // MARK: - Pairing agents

    @Test func pairingRePairsOnEveryReconnectAttempt() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        await h.placeCall()
        h.system.deliverTransportEvent(.connected)
        h.system.deliverTransportEvent(.disconnected(reason: .networkDropped))
        await h.system.awaitPendingReconnect()
        h.system.deliverTransportEvent(.disconnected(reason: .networkDropped))
        await h.system.awaitPendingReconnect()

        let expected = FakePairingResolver.Request(endpoint: endpoint, apiKey: "valid-token", kind: .daily)
        #expect(h.pairing.requests == Array(repeating: expected, count: 3))
        #expect(h.transport.lastConnection == CallConnection(
            url: URL(string: "https://example.daily.co/paired")!, token: "paired-token"
        ))
        #expect(h.transportRequests.kinds == [.daily])
    }

    @Test func unauthorizedPairingFailsWithBadToken() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        h.pairing.result = .failure(PairingError.unauthorized)
        await h.placeCall()

        #expect(h.engine.state.failureReason == .badToken)
        #expect(h.transport.connectCount == 0)
        #expect(try h.loggedEntries().first?.failureReason == .badToken)
    }

    @Test(arguments: [PairingError.invalidResponse, .server(503), .missingCredentials])
    func otherPairingFailuresFailWithTransportError(error: PairingError) async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        h.pairing.result = .failure(error)
        await h.placeCall()

        #expect(h.engine.state.failureReason == .transportError)
        #expect(h.transport.connectCount == 0)
    }

    @Test func pairingAgentWithoutAPIKeyStillPairs() async throws {
        let h = try AgentCallHostHarness(token: nil, pairingEndpoint: endpoint)
        await h.placeCall()

        #expect(h.pairing.requests.map(\.apiKey) == [""]) // an open endpoint is allowed
        #expect(h.transport.lastConnection == CallConnection(
            url: URL(string: "https://example.daily.co/paired")!, token: "paired-token"
        ))
        #expect(h.engine.state.isConnecting)
    }

    // MARK: - Join deadline

    @Test func anAgentThatNeverJoinsWritesAgentUnreachableRow() async throws {
        let h = try AgentCallHostHarness(joinTimeout: .seconds(30), sleep: AgentCallHostHarness.parkedSleep)
        await h.placeCall()
        #expect(h.engine.state.isConnecting)

        #expect(h.system.fireTimer(.joinTimeout))
        await h.system.awaitPendingWork()

        #expect(h.engine.state.failureReason == .agentUnreachable)
        let entry = try #require(try h.loggedEntries().first)
        #expect(entry.outcome == .failed)
        #expect(entry.failureReason == .agentUnreachable)
        #expect(entry.failureReasonRaw == CallFailureReason.agentUnreachable.rawValue)
        #expect(entry.outcomeDisplayLabel == "Failed — agent didn't join")
    }

    // MARK: - A phone call

    /// With the app's configuration a call cannot be held: a phone call the user
    /// accepts ends it, iOS ending it through CallKit, as a hangup from the system
    /// call screen would. The agent gets the end-call signal and Recents one row.
    @Test func aPhoneCallTheUserAcceptsEndsTheCall() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        await agentIsReady(h)
        h.announcer.finishAnnouncements()
        await h.system.awaitPendingWork()
        let callID = try #require(h.system.startedCallIDs.first)
        let transport = h.transport
        #expect(h.system.reportedSupportsHolding(callID) == false)

        let phoneCall = h.system.startOtherCall()
        #expect(!(await h.system.setHeldFromSystem(callID, onHold: true)))
        h.system.beginAudioInterruption()
        h.system.endCallFromSystem(callID)
        h.system.deactivateAudioSession()
        await h.system.awaitPendingWork()
        await h.system.endOtherCall(phoneCall)

        #expect(h.engine.state == .ended(.completed))
        #expect(!h.engine.isOnHold)
        #expect(h.system.holdRequests.isEmpty)
        #expect(transport.disconnectCount == 1)
        #expect(!transport.sentSignals.contains(.held))
        #expect(try h.loggedEntries().map(\.outcome) == [.completed])
    }

    /// iOS may never post an interruption's end (it did not after a phone call on
    /// iOS 27): CallKit handing the call its audio back ends "Paused" by itself.
    @Test func anInterruptionWhoseEndNeverComesDoesNotLeaveTheCallPaused() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        h.system.deliverTransportEvent(.connected)
        h.announcer.finishAnnouncements()
        await h.system.awaitPendingWork()

        h.system.beginAudioInterruption()
        h.system.deactivateAudioSession()
        await h.system.awaitPendingWork()
        #expect(InCallStatus.pausedText(for: h.engine.state, isInterrupted: h.engine.isInterrupted) == "Paused")

        await h.system.activateAudioSession()

        #expect(!h.engine.isInterrupted)
        #expect(InCallStatus.pausedText(for: h.engine.state, isInterrupted: h.engine.isInterrupted) == nil)
        #expect(h.transport.isMicEnabled)
    }

    // MARK: - The mic during the connect sounds

    /// A harness whose engine has the app's own configuration (the 2.6 s outgoing
    /// minimum included) and whose timers run out only when a test fires them,
    /// on a clock that does not move.
    private func soundsHarness(transportKind: TransportKind = .daily, token: String? = "valid-token") throws -> AgentCallHostHarness {
        let start = Date()
        return try AgentCallHostHarness(
            token: token,
            transportKind: transportKind,
            now: { start },
            configuration: AppEnvironment.callEngineConfiguration(),
            sleep: AgentCallHostHarness.parkedSleep
        )
    }

    /// The agent of a placed call is ready: the call stays connecting for the rest
    /// of the app's outgoing minimum, which then runs out.
    private func agentIsReady(_ h: AgentCallHostHarness) async {
        h.system.deliverTransportEvent(.connected)
        await h.system.awaitPendingWork()
        #expect(h.engine.state.isConnecting) // the ringback's first tone is still playing
        #expect(h.system.fireTimer(.minimumOutgoingConnectingDuration))
        await h.system.awaitPendingWork()
        #expect(h.engine.state.isConnected)
    }

    @Test func anOutgoingCallKeepsTheMicClosedUntilTheConnectSoundsAreDone() async throws {
        let h = try soundsHarness()
        #expect(AppEnvironment.callEngineConfiguration().minimumOutgoingConnectingDuration == .milliseconds(2600))
        await h.placeCall()
        await h.system.activateAudioSession()
        await h.system.awaitPendingWork()
        #expect(!h.engine.isMicWithheld) // the ringback needs none: the engine keeps the mic closed
        #expect(!h.transport.micEnabledHistory.contains(true))

        h.system.deliverTransportEvent(.connected) // the agent is ready inside the minimum
        await h.system.awaitPendingWork()
        #expect(h.engine.state.isConnecting)
        #expect(h.announcer.repeatingPhrase == .connecting) // the ringback plays on
        #expect(h.announcer.announced.isEmpty)
        #expect(!h.engine.isMicWithheld)
        #expect(!h.transport.micEnabledHistory.contains(true))
        #expect(h.transport.sentSignals.isEmpty)

        #expect(h.system.fireTimer(.minimumOutgoingConnectingDuration)) // the first tone is done
        await h.system.awaitPendingWork()
        #expect(h.engine.state.isConnected)
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.announced == [.connected])
        #expect(h.engine.isMicWithheld)
        #expect(!h.transport.micEnabledHistory.contains(true))
        #expect(!h.engine.isMuted) // not mute: CallKit and the call screen show it unmuted
        #expect(h.transport.sentSignals.isEmpty) // the agent waits for "Connected" too

        h.announcer.finishAnnouncements() // "Connected" has played
        await h.system.awaitPendingWork()

        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected]) // now the agent greets
    }

    @Test func aCallThatConnectsBeforeTheActivationKeepsTheMicClosedUntilTheSoundsAreDone() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await agentIsReady(h)
        await h.system.activateAudioSession() // "Connected" is announced here
        await h.system.awaitPendingWork()
        #expect(h.announcer.announced == [.connected])
        #expect(!h.transport.micEnabledHistory.contains(true))

        h.announcer.finishAnnouncements()
        await h.system.awaitPendingWork()

        #expect(h.transport.isMicEnabled)
    }

    @Test func anAnsweredRingKeepsTheMicClosedUntilTheConnectSoundsAreDone() async throws {
        let h = try soundsHarness()
        h.ring()
        #expect(!h.engine.isMicWithheld) // a ring plays nothing of ours
        await h.system.answerIncomingCall()
        #expect(!h.engine.isMicWithheld) // nor does the ringback need a withhold

        await h.system.activateAudioSession()
        h.system.deliverTransportEvent(.connected)
        await h.system.awaitPendingWork()
        #expect(!h.transport.micEnabledHistory.contains(true))

        h.announcer.finishAnnouncements()
        await h.system.awaitPendingWork()

        #expect(h.transport.isMicEnabled)
    }

    /// Answered with its agent already there, the user is on with the agent: nothing
    /// is said and nothing withheld, so the agent is told at CallKit's activation.
    @Test func aCallReadyAtTheAnswerSaysNothingAndTellsTheAgentAtTheActivation() async throws {
        let h = try AgentCallHostHarness(
            pairingEndpoint: endpoint, transportKind: .livekit, sleep: AgentCallHostHarness.parkedSleep
        )
        h.transport.canConnectWhileRinging = true
        h.ring(preconnect: "media")
        #expect(await h.system.awaitRingPreparation() == .connecting)
        h.system.deliverTransportEvent(.connected)
        await h.system.answerIncomingCall()
        #expect(h.engine.activeCall?.wasReadyAtAnswer == true)
        await h.system.awaitPendingWork()
        #expect(h.transport.sentSignals.isEmpty) // CallKit has not activated the audio yet

        await h.system.activateAudioSession()
        await h.system.awaitPendingWork()

        #expect(h.announcer.announced.isEmpty)
        #expect(h.announcer.startedRepeating.isEmpty)
        #expect(h.delays.waits.isEmpty)
        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isAudioAttached)
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected])
    }

    /// Its reconnects are cued as any call's are, with nothing withheld.
    @Test func aCallReadyAtTheAnswerStillMarksItsReconnects() async throws {
        let h = try AgentCallHostHarness(
            pairingEndpoint: endpoint, transportKind: .livekit, sleep: AgentCallHostHarness.parkedSleep
        )
        h.transport.canConnectWhileRinging = true
        h.ring(preconnect: "media")
        #expect(await h.system.awaitRingPreparation() == .connecting)
        h.system.deliverTransportEvent(.connected)
        await h.system.answerIncomingCall()
        await h.system.activateAudioSession()
        await h.system.awaitPendingWork()

        h.system.deliverTransportEvent(.reconnecting)
        #expect(h.announcer.repeatingPhrase == .retrying)
        h.system.deliverTransportEvent(.connected)
        await h.system.awaitPendingWork()

        #expect(h.announcer.announced == [.disconnected, .connected])
        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isMicEnabled)
    }

    // MARK: - Answered calls still connecting

    @Test func anAnsweredCallStillConnectingAfterASecondSaysConnectingOnce() async throws {
        let h = try soundsHarness()
        h.ring()
        await h.system.answerIncomingCall()
        await h.system.activateAudioSession()
        #expect(h.announcer.startedRepeating.isEmpty) // never a ringback after an answer
        #expect(h.announcer.announced.isEmpty)
        #expect(h.delays.waits == [AgentCallHost.connectingPromptDelay])
        #expect(AgentCallHost.connectingPromptDelay == .seconds(1))

        h.delays.fireAll() // a second, still connecting
        #expect(h.announcer.announced == [.connecting])

        h.system.deliverTransportEvent(.connected)
        await h.system.awaitPendingWork()
        #expect(h.announcer.announced == [.connecting, .connected])
        #expect(h.engine.isMicWithheld)
        #expect(!h.transport.micEnabledHistory.contains(true))
        #expect(h.transport.sentSignals.isEmpty)

        h.announcer.finishAnnouncements()
        await h.system.awaitPendingWork()
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected])
        #expect(h.announcer.startedRepeating.isEmpty)
    }

    @Test func anAnsweredCallThatConnectsWithinTheSecondSaysOnlyConnected() async throws {
        let h = try soundsHarness()
        h.ring()
        await h.system.answerIncomingCall()
        await h.system.activateAudioSession()
        h.system.deliverTransportEvent(.connected)
        await h.system.awaitPendingWork()

        h.delays.fireAll() // the second is up, but the call has connected

        #expect(h.announcer.announced == [.connected])
        #expect(h.announcer.startedRepeating.isEmpty)
        #expect(h.engine.isMicWithheld)
    }

    @Test func anAnsweredCallThatEndsBeforeTheSecondSaysNothing() async throws {
        let h = try soundsHarness()
        h.ring()
        await h.system.answerIncomingCall()

        await h.engine.endCall()
        h.delays.fireAll()

        #expect(h.announcer.announced.isEmpty)
    }

    /// The next answered call may say "Connecting" again.
    @Test func eachAnsweredCallSaysConnectingOnItsOwn() async throws {
        let h = try soundsHarness()
        h.ring()
        await h.system.answerIncomingCall()
        h.delays.fireAll()
        await h.engine.endCall()

        h.ring()
        await h.system.answerIncomingCall()
        h.delays.fireAll()

        #expect(h.announcer.announced == [.connecting, .connecting])
    }

    @Test func aPlacedCallRingsBackAndNeverSaysConnecting() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()

        #expect(h.announcer.startedRepeating == [.connecting])
        #expect(h.delays.waits.isEmpty)
        #expect(h.announcer.announced.isEmpty)
    }

    enum EndWhileConnecting: String, CaseIterable, Sendable {
        case byTheUser, fromTheSystem, byAProviderReset
    }

    @Test(arguments: EndWhileConnecting.allCases)
    func aCallThatEndsWhileConnectingLeavesNoWithhold(_ ending: EndWhileConnecting) async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        #expect(!h.engine.isMicWithheld)
        #expect(!h.transport.micEnabledHistory.contains(true))

        switch ending {
        case .byTheUser: await h.engine.endCall()
        case .fromTheSystem: h.system.endCallFromSystem(try #require(h.system.startedCallIDs.first))
        case .byAProviderReset: h.system.resetProvider()
        }

        #expect(h.engine.state.isTerminal)
        #expect(!h.engine.isMicWithheld)
    }

    @Test func aCallThatFailsWhileConnectingReleasesTheMic() async throws {
        let h = try soundsHarness(token: nil)
        await h.placeCall()

        #expect(h.engine.state.failureReason == .badToken)
        #expect(h.announcer.startedRepeating == [.connecting])
        #expect(!h.engine.isMicWithheld)
    }

    /// A drop while the first "Connected" still plays: the reconnect cuts it off,
    /// which releases its withhold, and its late completion changes nothing.
    @Test func aReconnectCutsOffTheFirstConnectedAndReleasesItsWithhold() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        await agentIsReady(h)
        #expect(h.engine.isMicWithheld)
        h.system.deliverTransportEvent(.disconnected(reason: .networkDropped))
        #expect(h.system.fireTimer(.reconnectBackoff))
        await h.system.awaitPendingReconnect()
        h.system.deliverTransportEvent(.connected) // back
        await h.system.awaitPendingWork()

        #expect(h.announcer.cutOffCount == 2) // before each "Connected"
        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isMicEnabled)

        h.announcer.finishOldestAnnouncement() // a late completion
        await h.system.awaitPendingWork()
        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isMicEnabled)
    }

    @Test func endingTheCallCutsItsConnectedOff() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        await agentIsReady(h)
        #expect(h.announcer.unfinishedAnnouncementCount == 1)

        await h.engine.endCall()

        #expect(h.announcer.stopNowCount >= 1)
        #expect(h.announcer.unfinishedAnnouncementCount == 0)
        #expect(!h.engine.isMicWithheld)
    }

    /// After a reconnect the user can talk at once: "Connected" is said with the
    /// mic open. On a device a LiveKit reconnect's "Connected" did not finish
    /// within 5 s, which the withhold turned into 5 s of dead mic.
    @Test func aReconnectSaysConnectedWithTheMicOpen() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        await agentIsReady(h)
        h.announcer.finishAnnouncements()
        await h.system.awaitPendingWork()
        #expect(!h.engine.isMicWithheld)

        h.system.deliverTransportEvent(.reconnecting) // "Disconnected", then the retrying loop
        #expect(h.announcer.repeatingPhrase == .retrying)
        #expect(!h.engine.isMicWithheld)

        h.system.deliverTransportEvent(.connected) // back: "Connected"
        await h.system.awaitPendingWork()
        #expect(h.announcer.announced == [.connected, .disconnected, .connected])
        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isMicEnabled) // before "Connected" has played
        #expect(h.transport.sentSignals == [.connected, .connected])
        #expect(!h.system.fireTimer(.micWithholdTimeout)) // nothing to bound
    }

    /// Whatever is still queued or speaking from the outage is stale once the call
    /// is back: "Connected" cuts it off first, after the retrying loop stops.
    @Test func everyConnectedCutsOffWhatIsQueuedFirst() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        await agentIsReady(h)
        #expect(Array(h.announcer.events.suffix(3)) == [.stopRepeating, .cutOff, .announce(.connected)])
        h.announcer.finishAnnouncements()
        await h.system.awaitPendingWork()

        h.system.deliverTransportEvent(.reconnecting)
        h.system.deliverTransportEvent(.connected)
        await h.system.awaitPendingWork()

        #expect(Array(h.announcer.events.suffix(5)) == [
            .announce(.disconnected), .startRepeating(.retrying),
            .stopRepeating, .cutOff, .announce(.connected),
        ])
    }

    /// The first "Connected" of a call still withholds the mic, but one the
    /// synthesizer never starts is cut off at the announcer's start bound, whose
    /// completion releases the mic: the withhold never waits for the engine's 5 s.
    @Test func aFirstConnectedThatNeverStartsReleasesTheMicAtTheStartBound() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        await agentIsReady(h)
        await h.system.awaitPendingWork()
        #expect(h.engine.isMicWithheld)

        h.announcer.expireUnstartedAnnouncements()
        await h.system.awaitPendingWork()

        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isMicEnabled)
        #expect(h.transport.sentSignals == [.connected])
        #expect(h.system.fireTimer(.micWithholdTimeout) == false)
    }

    /// One that started is not cut off by the bound: it plays out, withheld.
    @Test func aFirstConnectedThatStartedKeepsItsWithholdUntilItFinishes() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        await agentIsReady(h)
        h.announcer.startAnnouncements()
        h.announcer.expireUnstartedAnnouncements()
        await h.system.awaitPendingWork()
        #expect(h.engine.isMicWithheld)

        h.announcer.finishAnnouncements()
        await h.system.awaitPendingWork()
        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isMicEnabled)
    }

    @Test func soundsThatNeverFinishLeaveTheMicToTheEnginesBound() async throws {
        let h = try soundsHarness()
        await h.placeCall()
        await h.system.activateAudioSession()
        await agentIsReady(h)
        await h.system.awaitPendingWork()
        #expect(!h.transport.isMicEnabled)

        #expect(h.system.fireTimer(.micWithholdTimeout))
        await h.system.awaitPendingWork()
        #expect(!h.engine.isMicWithheld)
        #expect(h.transport.isMicEnabled)

        h.announcer.finishAnnouncements() // a late completion releases nothing more
        await h.system.awaitPendingWork()
        #expect(h.transport.isMicEnabled)
    }

    // MARK: - Pre-connect

    @Test(arguments: RingPreparation.allCases)
    func incomingTargetAllowsWhatThePushAsksFor(requested: RingPreparation) throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        let call = IncomingCall(
            callID: UUID(), targetID: h.agent.id, displayName: h.agent.name,
            handle: h.agent.syntheticEmail, connection: nil, requestedPreparation: requested
        )

        let target = try #require(h.host.callEngine(h.engine, targetForIncomingCall: call))
        #expect(target.ringPreparation == requested)
    }

    /// A fixed room (direct mode, no pairing endpoint) has a bot nobody told whether
    /// this app sends `call-connected`: the app never joins it before the answer,
    /// where a bot that greets on the device's join would speak into the ring.
    /// The credentials tier, the room it already has, is harmless.
    @Test(arguments: RingPreparation.allCases)
    func aFixedRoomIsNeverJoinedBeforeTheAnswer(requested: RingPreparation) throws {
        let h = try AgentCallHostHarness() // direct mode
        let call = IncomingCall(
            callID: UUID(), targetID: h.agent.id, displayName: h.agent.name,
            handle: h.agent.syntheticEmail, connection: nil, requestedPreparation: requested
        )

        let target = try #require(h.host.callEngine(h.engine, targetForIncomingCall: call))
        #expect(target.ringPreparation == min(requested, .credentials))
    }

    /// Inline credentials come from the server that rang, which has the device's
    /// registration and its `call_signals`, and made the room: what it asks for stands.
    @Test func aRingWithInlineCredentialsGetsWhatItAsksForEvenForADirectAgent() throws {
        let h = try AgentCallHostHarness()
        let call = IncomingCall(
            callID: UUID(), targetID: h.agent.id, displayName: h.agent.name,
            handle: h.agent.syntheticEmail,
            connection: CallConnection(url: URL(string: "https://example.daily.co/inline")!, token: "t"),
            requestedPreparation: .media
        )

        let target = try #require(h.host.callEngine(h.engine, targetForIncomingCall: call))
        #expect(target.ringPreparation == .media)
    }

    /// The whole path: a direct agent's media ring fetches its room during the ring
    /// but joins only after the answer.
    @Test func aDirectAgentsMediaRingJoinsOnlyAfterTheAnswer() async throws {
        let h = try AgentCallHostHarness()
        h.transport.canConnectWhileRinging = true
        h.ring(preconnect: "media")
        #expect(await h.system.awaitRingPreparation() == .credentialsReady)
        #expect(h.transport.connectCount == 0)

        await h.system.answerIncomingCall()
        await h.system.awaitPendingWork()
        #expect(h.transport.connectCount == 1)
    }

    @Test func outgoingTargetsAllowNoRingPreparation() throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        #expect(h.host.target(for: h.agent).ringPreparation == .none)
    }

    @Test func aRingWithoutPreconnectPairsOnlyAfterTheAnswer() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        h.ring()
        #expect(await h.system.awaitRingPreparation() == .idle)
        await h.system.awaitPendingWork()
        #expect(h.pairing.requests.isEmpty)

        await h.system.answerIncomingCall()
        #expect(h.pairing.requests.map(\.ring) == [nil])
    }

    @Test func aCredentialsRingPairsForTheRingAndAnswersWithIt() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        let callID = UUID()
        h.ring(callID: callID, preconnect: "credentials")
        #expect(await h.system.awaitRingPreparation() == .credentialsReady)

        #expect(h.engine.state == .incomingRinging)
        #expect(h.pairing.requests == [FakePairingResolver.Request(
            endpoint: endpoint, apiKey: "valid-token", kind: .daily,
            ring: PairingRing(callID: callID, joinsBeforeAnswer: false)
        )])
        #expect(h.transports.made.allSatisfy { $0.connectCount == 0 })

        await h.system.answerIncomingCall()
        #expect(h.pairing.requests.count == 1) // the ring's credentials are used
        #expect(h.transport.lastConnection == CallConnection(
            url: URL(string: "https://example.daily.co/paired")!, token: "paired-token"
        ))
    }

    @Test func aMediaRingJoinsBeforeTheAnswerAndConnectsSilentlyOnIt() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint, transportKind: .livekit)
        h.transport.canConnectWhileRinging = true
        let callID = UUID()
        h.ring(callID: callID, preconnect: "media")
        #expect(await h.system.awaitRingPreparation() == .connecting)

        #expect(h.transport.connectCount == 1)
        #expect(h.pairing.requests.map(\.ring) == [PairingRing(callID: callID, joinsBeforeAnswer: true)])
        #expect(!h.transport.isAudioAttached)
        h.system.deliverTransportEvent(.connected)
        #expect(h.engine.ringPreparationPhase == .ready)
        #expect(h.engine.state == .incomingRinging)
        #expect(h.announcer.announced.isEmpty)

        await h.system.answerIncomingCall()
        await h.system.activateAudioSession()
        await h.system.awaitPendingWork()

        if case .connected = h.engine.state {} else {
            Issue.record("Expected connected at the answer, got \(h.engine.state)")
        }
        #expect(h.pairing.requests.count == 1)
        #expect(h.transport.connectCount == 1)
        #expect(h.transport.ringingConnectCount == 1)
        #expect(h.announcer.startedRepeating.isEmpty) // no ringback
        #expect(h.announcer.announced.isEmpty) // the user is already on with the agent
        #expect(h.transport.sentSignals == [.connected])
    }

    @Test func aMediaRingOnATransportThatCannotJoinWhileRingingOnlyPairs() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        let callID = UUID()
        h.ring(callID: callID, preconnect: "media")
        #expect(await h.system.awaitRingPreparation() == .credentialsReady)

        #expect(h.pairing.requests.map(\.ring) == [PairingRing(callID: callID, joinsBeforeAnswer: false)])
        #expect(h.transports.made.allSatisfy { $0.connectCount == 0 })
    }

    @Test func aPreconnectRingWithInlineCredentialsMakesNoNetworkCall() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        let room = URL(string: "https://example.daily.co/inbound-room")!
        h.ring(roomURL: room, token: "push-token", preconnect: "credentials")
        #expect(await h.system.awaitRingPreparation() == .credentialsReady)

        await h.system.answerIncomingCall()
        #expect(h.pairing.requests.isEmpty)
        #expect(h.transport.lastConnection == CallConnection(url: room, token: "push-token"))
    }

    // MARK: - VoIP token registration

    private func inboundAgent(
        named name: String, in h: AgentCallHostHarness, apiKey: String, transportKind: TransportKind = .daily
    ) throws -> Agent {
        let agent = Agent(
            name: name, transportKind: transportKind,
            pairingEndpoint: URL(string: "https://engine.example.com/connect/\(name)")!,
            inboundRegistrationURL: RecordingURLProtocol.uniqueEndpoint()
        )
        h.repository.insert(agent)
        try h.repository.save()
        try h.keychain.setToken(apiKey, for: KeychainTokenRef(account: agent.keychainTokenRef))
        return agent
    }

    private func body(_ request: RecordingURLProtocol.Captured) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func tokenUpdateRegistersWithEveryInboundAgent() async throws {
        let h = try AgentCallHostHarness() // the harness agent has no inbound URL
        let nova = try inboundAgent(named: "Nova", in: h, apiKey: "nova-key", transportKind: .livekit)
        let atlas = try inboundAgent(named: "Atlas", in: h, apiKey: "atlas-key", transportKind: .smallwebrtc)
        h.engine.startPushRegistration()

        h.system.deliverVoIPPushToken(Data([0xAB, 0x01]))
        await h.host.awaitPendingRegistration()

        for (agent, key) in [(nova, "nova-key"), (atlas, "atlas-key")] {
            let host = try #require(agent.inboundRegistrationURL?.host())
            let requests = RecordingURLProtocol.requests(host: host)
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request.method == "POST")
            #expect(request.headers["Authorization"] == "Bearer \(key)")
            let fields = try body(request)
            #expect(fields["voip_token"] as? String == "ab01")
            #expect(fields["agent_id"] as? String == agent.id.uuidString)
            #expect(fields["display_name"] as? String == agent.name)
            #expect(fields["handle"] as? String == agent.syntheticEmail)
            #expect(fields["push_features"] as? [String] == CallEngine.supportedPushFeatures.sorted())
            // The server prepares a ring's room on it: the same value as the pairing body's.
            #expect(fields["transport"] as? String == agent.transportKind.rawValue)
            #expect(fields["transport"] as? String == PairingClient.body(transport: agent.transportKind, ring: nil)["transport"] as? String)
        }
        #expect(nova.transportKind.rawValue == "livekit")
        #expect(atlas.transportKind.rawValue == "smallwebrtc")
    }

    @Test func registerInboundUsesTheEnginesCurrentToken() async throws {
        let h = try AgentCallHostHarness()
        let nova = try inboundAgent(named: "Nova", in: h, apiKey: "nova-key")
        let host = try #require(nova.inboundRegistrationURL?.host())

        await h.host.registerInbound(for: nova) // PushKit hasn't issued a token yet
        #expect(RecordingURLProtocol.requests(host: host).isEmpty)

        h.system.voipPushToken = Data([0x0F, 0xA0])
        await h.host.registerInbound(for: nova)

        let requests = RecordingURLProtocol.requests(host: host)
        #expect(requests.count == 1)
        #expect(try requests.first.map(body)?["voip_token"] as? String == "0fa0")
    }

    @Test func aTokenPushKitInvalidatesIsNoLongerRegistered() async throws {
        let h = try AgentCallHostHarness()
        let nova = try inboundAgent(named: "Nova", in: h, apiKey: "nova-key")
        let host = try #require(nova.inboundRegistrationURL?.host())
        h.system.deliverVoIPPushToken(Data([0xAB, 0x01]))
        await h.host.awaitPendingRegistration()
        #expect(RecordingURLProtocol.requests(host: host).count == 1)

        h.system.invalidateVoIPPushToken()
        await h.host.registerInbound(for: nova)

        #expect(h.engine.voipPushToken == nil)
        #expect(RecordingURLProtocol.requests(host: host).count == 1)
    }

    @Test func registrationBodyCarriesAllNineKeys() async throws {
        let endpoint = RecordingURLProtocol.uniqueEndpoint()
        let agentID = UUID()
        await PushTokenRegistrar.register(
            token: "ab01",
            agentID: agentID,
            displayName: "Nova",
            handle: "nova@conduit.invalid",
            endpoint: endpoint,
            apiKey: "nova-key",
            transport: .livekit,
            bundleID: "com.example.conduit",
            pushFeatures: ["cancel", "ring_timeout"],
            session: RecordingURLProtocol.session()
        )

        let host = try #require(endpoint.host())
        let request = try #require(RecordingURLProtocol.requests(host: host).first)
        let fields = try body(request)
        #expect(fields.count == 9)
        #expect(fields["transport"] as? String == "livekit")
        // An agent the server starts for a ring waits for call-connected only from a
        // registration that lists it.
        #expect(fields["call_signals"] as? [String] == ["call-connected"])
        #expect(fields["voip_token"] as? String == "ab01")
        #expect(fields["platform"] as? String == "ios")
        #expect(fields["bundle_id"] as? String == "com.example.conduit")
        #expect(fields["agent_id"] as? String == agentID.uuidString)
        #expect(fields["display_name"] as? String == "Nova")
        #expect(fields["handle"] as? String == "nova@conduit.invalid")
        #expect(fields["push_features"] as? [String] == ["cancel", "ring_timeout"])
        #expect(request.headers["Authorization"] == "Bearer nova-key")
        #expect(request.headers["Content-Type"] == "application/json")
    }

    @Test func registrationSendsAtMost120CharactersOfTheName() async throws {
        let endpoint = RecordingURLProtocol.uniqueEndpoint()
        let longName = String(repeating: "N", count: 200)
        await PushTokenRegistrar.register(
            token: "ab01",
            agentID: UUID(),
            displayName: longName,
            handle: "nova@conduit.invalid",
            endpoint: endpoint,
            apiKey: "",
            transport: .daily,
            session: RecordingURLProtocol.session()
        )

        let host = try #require(endpoint.host())
        let request = try #require(RecordingURLProtocol.requests(host: host).first)
        let name = try #require(try body(request)["display_name"] as? String)
        #expect(name.unicodeScalars.count == 120) // the backend rejects over 128
        #expect(longName.hasPrefix(name))
    }
}

