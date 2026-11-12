//
//  AgentCallHostTests.swift
//  ConduitTests
//
//  Conduit's side of the call engine, driven by the real engine against
//  fakes: the call-log rows it writes from each record, the engine's cues it
//  speaks, Siri donation, missed-call
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
        let sleeper = ManualSleeper()
        let h = try AgentCallHostHarness(ringTimeout: .seconds(60), sleep: { try await sleeper.sleep($0) })
        h.ring()
        #expect(h.engine.state == .incomingRinging)

        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.fireAll()
        await waitUntil { h.engine.state == .idle }

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
        let h = try AgentCallHostHarness()
        await h.placeCall()
        #expect(h.announcer.startedRepeating == [.connecting])
        #expect(h.announcer.repeatingPhrase == .connecting)

        h.system.deliverTransportEvent(.connected)
        #expect(h.announcer.announced == [.connected])
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.stopRepeatingCount == 1)
    }

    @Test func dropAndRecoveryCuesDisconnectedOnceThenConnected() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
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

    @Test func answerStartsConnectingCueWithoutDonation() async throws {
        let h = try AgentCallHostHarness()
        h.ring()
        await h.system.answerIncomingCall()

        #expect(h.announcer.startedRepeating == [.connecting])
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

    @Test func outgoingTargetsAllowNoRingPreparation() throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        #expect(h.host.target(for: h.agent).ringPreparation == .none)
    }

    @Test func aRingWithoutPreconnectPairsOnlyAfterTheAnswer() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        h.ring()
        await waitUntil(ticks: 50) { !h.pairing.requests.isEmpty }
        #expect(h.pairing.requests.isEmpty)
        #expect(h.engine.ringPreparationPhase == .idle)

        await h.system.answerIncomingCall()
        #expect(h.pairing.requests.map(\.ring) == [nil])
    }

    @Test func aCredentialsRingPairsForTheRingAndAnswersWithIt() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        let callID = UUID()
        h.ring(callID: callID, preconnect: "credentials")
        await waitUntil { h.engine.ringPreparationPhase == .credentialsReady }

        #expect(h.engine.state == .incomingRinging)
        #expect(h.pairing.requests == [FakePairingResolver.Request(
            endpoint: endpoint, apiKey: "valid-token", kind: .daily,
            ring: PairingRing(callID: callID, awaitAnswer: false)
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
        await waitUntil { h.transport.connectCount == 1 }

        #expect(h.pairing.requests.map(\.ring) == [PairingRing(callID: callID, awaitAnswer: true)])
        #expect(h.engine.ringPreparationPhase == .connecting)
        #expect(!h.transport.isAudioAttached)
        h.system.deliverTransportEvent(.connected)
        #expect(h.engine.ringPreparationPhase == .ready)
        #expect(h.engine.state == .incomingRinging)
        #expect(h.announcer.announced.isEmpty)

        await h.system.answerIncomingCall()
        await h.system.activateAudioSession()
        await waitUntil { h.transport.sentSignals.contains(.answered) }

        if case .connected = h.engine.state {} else {
            Issue.record("Expected connected at the answer, got \(h.engine.state)")
        }
        #expect(h.pairing.requests.count == 1)
        #expect(h.transport.connectCount == 1)
        #expect(h.announcer.startedRepeating.isEmpty) // no ringback
        #expect(h.announcer.announced == [.connected])
        #expect(h.transport.sentSignals == [.answered])
    }

    @Test func aMediaRingOnATransportThatCannotJoinWhileRingingOnlyPairs() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        let callID = UUID()
        h.ring(callID: callID, preconnect: "media")
        await waitUntil { h.engine.ringPreparationPhase == .credentialsReady }

        #expect(h.pairing.requests.map(\.ring) == [PairingRing(callID: callID, awaitAnswer: false)])
        #expect(h.transports.made.allSatisfy { $0.connectCount == 0 })
    }

    @Test func aPreconnectRingWithInlineCredentialsMakesNoNetworkCall() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        let room = URL(string: "https://example.daily.co/inbound-room")!
        h.ring(roomURL: room, token: "push-token", preconnect: "credentials")
        await waitUntil { h.engine.ringPreparationPhase == .credentialsReady }

        await h.system.answerIncomingCall()
        #expect(h.pairing.requests.isEmpty)
        #expect(h.transport.lastConnection == CallConnection(url: room, token: "push-token"))
    }

    // MARK: - VoIP token registration

    private func inboundAgent(named name: String, in h: AgentCallHostHarness, apiKey: String) throws -> Agent {
        let agent = Agent(
            name: name, transportKind: .daily,
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
        let nova = try inboundAgent(named: "Nova", in: h, apiKey: "nova-key")
        let atlas = try inboundAgent(named: "Atlas", in: h, apiKey: "atlas-key")
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
        }
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

    @Test func registrationBodyCarriesAllSevenKeys() async throws {
        let endpoint = RecordingURLProtocol.uniqueEndpoint()
        let agentID = UUID()
        await PushTokenRegistrar.register(
            token: "ab01",
            agentID: agentID,
            displayName: "Nova",
            handle: "nova@conduit.invalid",
            endpoint: endpoint,
            apiKey: "nova-key",
            bundleID: "com.example.conduit",
            pushFeatures: ["cancel", "ring_timeout"],
            session: RecordingURLProtocol.session()
        )

        let host = try #require(endpoint.host())
        let request = try #require(RecordingURLProtocol.requests(host: host).first)
        let fields = try body(request)
        #expect(fields.count == 7)
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
            session: RecordingURLProtocol.session()
        )

        let host = try #require(endpoint.host())
        let request = try #require(RecordingURLProtocol.requests(host: host).first)
        let name = try #require(try body(request)["display_name"] as? String)
        #expect(name.unicodeScalars.count == 120) // the backend rejects over 128
        #expect(longName.hasPrefix(name))
    }
}

