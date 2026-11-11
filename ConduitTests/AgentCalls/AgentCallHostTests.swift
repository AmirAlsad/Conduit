//
//  AgentCallHostTests.swift
//  ConduitTests
//
//  Conduit's side of the call engine, driven by the real engine against
//  fakes: the call-log rows it writes from each record, the spoken cues it derives
//  from transitions, Siri donation, missed-call notifications, the receipt bearer,
//  and the agent targets it hands the engine (direct, pairing, inline push).
//

import Foundation
import Testing
@testable import Conduit

@MainActor
struct AgentCallHostTests {

    private let endpoint = URL(string: "https://engine.example.com/connect/live")!
    private let statusEndpoint = URL(string: "https://engine.example.com/inbound/status/live")!

    // MARK: - History rows

    @Test func completedCallWritesHistoryRow() async throws {
        let clock = MutableClock()
        let h = try AgentCallHostHarness(now: clock.now)
        await h.placeCall()
        h.engine.handle(.connected)
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
        h.engine.handle(.connected)
        h.engine.providerPerformEndCall(h.callID)

        #expect(try h.loggedEntries().map(\.outcome) == [.completed])
    }

    @Test func answeredCallWritesIncomingRow() async throws {
        let h = try AgentCallHostHarness()
        h.ring()
        await h.engine.answer()
        h.engine.handle(.connected)
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
        h.engine.providerPerformEndCall(callID)

        let entry = try #require(try h.loggedEntries().first)
        #expect(entry.direction == .incoming)
        #expect(entry.outcome == .declined)
        #expect(h.missedNotifier.missedAgentNames.isEmpty)
    }

    @Test func unknownTargetWritesNoRow() async throws {
        let h = try AgentCallHostHarness()
        h.ring(agentID: UUID())

        #expect(h.engine.state.failureReason == .unknown)
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
        #expect(h.missedNotifier.missedAgentNames == [h.agent.name])
        // Rang under the push's fallbacks, corrected to the agent before it ended.
        #expect(h.provider.updatedCalls.first?.handle == h.agent.callHandle)
        #expect(h.provider.updatedCalls.first?.displayName == h.agent.name)
    }

    @Test func focusFilteredRingWritesMissedRowAndNotifies() async throws {
        let h = try AgentCallHostHarness()
        h.provider.reportIncomingError = IncomingCallReportError.filteredByFocus
        h.ring()

        #expect(h.engine.state == .idle)
        let entries = try h.loggedEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.direction == .incoming)
        #expect(entries.first?.outcome == .noAnswer)
        #expect(h.missedNotifier.missedAgentNames == [h.agent.name])
    }

    @Test func remoteEndBeforeConnectWritesNoAnswerWithoutNotification() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        h.engine.handle(.disconnected(reason: .botLeft))

        // Preserved as-is: the state says completed while the row says no answer.
        #expect(h.engine.state.endedOutcome == .completed)
        #expect(try h.loggedEntries().map(\.outcome) == [.noAnswer])
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

        h.engine.handle(.connected)
        #expect(h.announcer.announced == [.connected])
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.stopRepeatingCount == 1)
    }

    @Test func dropAndRecoveryCuesDisconnectedOnceThenConnected() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.handle(.disconnected(reason: .networkDropped))
        #expect(h.announcer.announced.contains(.disconnected))
        #expect(h.announcer.startedRepeating.contains(.retrying))
        await h.engine.awaitPendingReconnect()

        h.engine.handle(.disconnected(reason: .networkDropped)) // attempt 2: no new cue
        await h.engine.awaitPendingReconnect()

        h.engine.handle(.connected)
        #expect(h.announcer.repeatingPhrase == nil)
        #expect(h.announcer.announced == [.connected, .disconnected, .connected])
        #expect(h.announcer.startedRepeating == [.connecting, .retrying])
    }

    @Test func selfHealThenDropAnnouncesDisconnectedTwice() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        h.engine.handle(.connected)

        h.engine.handle(.reconnecting) // the transport self-heals (display only)
        #expect(h.announcer.announced.contains(.disconnected))
        #expect(h.announcer.startedRepeating.contains(.retrying))

        h.engine.handle(.disconnected(reason: .networkDropped)) // then drops for real
        #expect(h.announcer.announced == [.connected, .disconnected, .disconnected])
        #expect(h.announcer.startedRepeating == [.connecting, .retrying, .retrying])
    }

    @Test func duplicateConnectedAnnouncesOnce() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        h.engine.handle(.connected)

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

    @Test func providerResetLeavesTheAnnouncerRunning() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()

        h.engine.providerWasReset()

        // Preserved as-is: a provider reset neither stops the cue nor writes history.
        #expect(h.engine.state == .idle)
        #expect(h.announcer.repeatingPhrase == .connecting)
        #expect(h.announcer.stopRepeatingCount == 0)
        #expect(try h.loggedEntries().isEmpty)
    }

    // MARK: - Siri donation

    @Test func outgoingCallDonatesOnce() async throws {
        let h = try AgentCallHostHarness()
        h.provider.suspendStart = true
        h.transport.suspendConnect = true // the transport this call will get

        let place = Task { await h.placeCall() }
        await waitUntil { h.provider.pendingStartCount == 1 }
        #expect(h.provider.pendingStartCount == 1)
        #expect(h.interactionDonor.donatedAgentIDs.isEmpty) // not while dialing

        h.provider.releaseStart()
        await waitUntil { h.transport.connectCount == 1 }
        #expect(h.engine.state.isConnecting)
        #expect(h.interactionDonor.donatedAgentIDs == [h.agent.id]) // on dialing → connecting

        h.transport.releaseConnect()
        await place.value
        h.engine.handle(.connected)
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
        await h.engine.answer()

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
        await h.engine.answer()

        #expect(h.ringStatusReporter.reports == [
            .init(status: .answered, callID: callID, endpoint: statusEndpoint, apiKey: "agent-api-key")
        ])
    }

    // MARK: - Incoming targets

    @Test func receiveCallRingsAndResolvesAgent() async throws {
        let h = try AgentCallHostHarness()
        let callID = UUID()
        h.ring(callID: callID)

        #expect(h.engine.state == .incomingRinging)
        #expect(h.engine.activeCall?.targetID == h.agent.id)
        #expect(h.engine.activeCall?.displayName == h.agent.name)
        #expect(h.provider.reportedIncoming.map(\.id) == [callID])
        #expect(h.provider.updatedCalls.first?.handle == h.agent.callHandle)
    }

    @Test func ringWithoutIdentityIsCorrectedToTheAgent() async throws {
        let h = try AgentCallHostHarness()
        let callID = UUID()
        h.ring(callID: callID) // no display_name, no handle

        let reported = try #require(h.provider.reportedIncoming.first)
        #expect(reported.displayName == "Agent")
        #expect(reported.handle == CallHandle(value: CallTarget.defaultHandle(for: h.agent.id)))
        let corrected = try #require(h.provider.updatedCalls.first)
        #expect(corrected.id == callID)
        #expect(corrected.displayName == h.agent.name)
        #expect(corrected.handle == CallHandle(value: h.agent.syntheticEmail))
        #expect(h.provider.updatedCalls.count == 1)
    }

    @Test func ringUnderTheAgentsOwnIdentityIsNotCorrected() async throws {
        let h = try AgentCallHostHarness()
        h.ring(displayName: h.agent.name, handle: h.agent.syntheticEmail)

        #expect(h.provider.reportedIncoming.first?.handle == h.agent.callHandle)
        #expect(h.provider.updatedCalls.isEmpty)
        #expect(h.engine.state == .incomingRinging)
    }

    @Test func answerConnectsViaAgentDirectConfig() async throws {
        let h = try AgentCallHostHarness()
        h.ring()
        await h.engine.answer()

        #expect(h.transport.connectCount == 1)
        #expect(h.transport.lastConnection?.token == "valid-token")
        #expect(h.transport.lastConnection?.url == h.agent.connectionURL)
        #expect(h.engine.state.isConnecting)
    }

    @Test func answerWithInlineCredentialsJoinsDirectly() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint) // inline wins over pairing
        let room = URL(string: "https://example.daily.co/inbound-room")!
        h.ring(roomURL: room, token: "push-token")
        await h.engine.answer()

        #expect(h.transport.lastConnection?.url == room)
        #expect(h.transport.lastConnection?.token == "push-token")
        #expect(h.pairing.requests.isEmpty)
    }

    @Test func directCredentialsRepeatOnEveryAttempt() async throws {
        let h = try AgentCallHostHarness()
        await h.placeCall()
        h.engine.handle(.connected)
        let first = try #require(h.transport.lastConnection)
        #expect(first == CallConnection(url: try #require(h.agent.connectionURL), token: "valid-token"))

        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()

        #expect(h.transport.connectCount == 2)
        #expect(h.transport.lastConnection == first)
        #expect(h.pairing.requests.isEmpty)
    }

    @Test func inlinePushCredentialsRepeatOnEveryAttempt() async throws {
        let h = try AgentCallHostHarness()
        let room = URL(string: "https://example.daily.co/inbound-room")!
        h.ring(roomURL: room, token: "push-token")
        await h.engine.answer()
        h.engine.handle(.connected)

        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()

        #expect(h.transport.connectCount == 2)
        #expect(h.transport.lastConnection == CallConnection(url: room, token: "push-token"))
        #expect(h.pairing.requests.isEmpty)
    }

    // MARK: - Pairing agents

    @Test func pairingRePairsOnEveryReconnectAttempt() async throws {
        let h = try AgentCallHostHarness(pairingEndpoint: endpoint)
        await h.placeCall()
        h.engine.handle(.connected)
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()
        h.engine.handle(.disconnected(reason: .networkDropped))
        await h.engine.awaitPendingReconnect()

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

    private func body(_ request: RecordingURLProtocol.Captured) throws -> [String: String] {
        try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: String])
    }

    @Test func tokenUpdateRegistersWithEveryInboundAgent() async throws {
        let h = try AgentCallHostHarness() // the harness agent has no inbound URL
        let nova = try inboundAgent(named: "Nova", in: h, apiKey: "nova-key")
        let atlas = try inboundAgent(named: "Atlas", in: h, apiKey: "atlas-key")
        h.engine.startPushRegistration()

        h.pushRegistry.simulateTokenUpdate(Data([0xAB, 0x01]))
        await h.host.awaitPendingRegistration()

        for (agent, key) in [(nova, "nova-key"), (atlas, "atlas-key")] {
            let host = try #require(agent.inboundRegistrationURL?.host())
            let requests = RecordingURLProtocol.requests(host: host)
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request.method == "POST")
            #expect(request.headers["Authorization"] == "Bearer \(key)")
            let fields = try body(request)
            #expect(fields["voip_token"] == "ab01")
            #expect(fields["agent_id"] == agent.id.uuidString)
            #expect(fields["display_name"] == agent.name)
            #expect(fields["handle"] == agent.syntheticEmail)
        }
    }

    @Test func registerInboundUsesTheEnginesCurrentToken() async throws {
        let h = try AgentCallHostHarness()
        let nova = try inboundAgent(named: "Nova", in: h, apiKey: "nova-key")
        let host = try #require(nova.inboundRegistrationURL?.host())

        await h.host.registerInbound(for: nova) // PushKit hasn't issued a token yet
        #expect(RecordingURLProtocol.requests(host: host).isEmpty)

        h.pushRegistry.pushToken = Data([0x0F, 0xA0])
        await h.host.registerInbound(for: nova)

        let requests = RecordingURLProtocol.requests(host: host)
        #expect(requests.count == 1)
        #expect(try requests.first.map(body)?["voip_token"] == "0fa0")
    }

    @Test func registrationBodyCarriesAllSixKeys() async throws {
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
            session: RecordingURLProtocol.session()
        )

        let host = try #require(endpoint.host())
        let request = try #require(RecordingURLProtocol.requests(host: host).first)
        #expect(try body(request) == [
            "voip_token": "ab01",
            "platform": "ios",
            "bundle_id": "com.example.conduit",
            "agent_id": agentID.uuidString,
            "display_name": "Nova",
            "handle": "nova@conduit.invalid",
        ])
        #expect(request.headers["Authorization"] == "Bearer nova-key")
        #expect(request.headers["Content-Type"] == "application/json")
    }
}
