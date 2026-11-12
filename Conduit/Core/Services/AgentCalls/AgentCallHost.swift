//
//  AgentCallHost.swift
//  Conduit
//
//  Conduit's side of the call engine: turns agents into call targets (allowing
//  the ring preparation each push asks for) and reacts to what the engine
//  reports — writing the call log, speaking the engine's cues, donating outgoing
//  calls to Siri, posting missed-call notifications, supplying the API key that
//  authenticates ring-status receipts, and registering the device's VoIP token
//  with every agent that lets itself call the user. The
//  engine identifies calls only by target id; this looks the agent up, and a
//  target with no agent (unknown or deleted) records nothing.
//
//  The cues: a call the user placed gets the ringback while it connects, then
//  "Connected" with the mic withheld while it plays (after which the engine tells
//  the agent the user is on the line). A call the user answered never gets a
//  ringback: answered with its agent already there, it says nothing, so the agent
//  hears the user as soon as CallKit activates the audio; still connecting a second
//  after the answer, it says "Connecting" once, then "Connected" as a placed call
//  does. Reconnect cues are the same for both, except that "Connected" after a
//  reconnect withholds nothing: the user can talk the moment the call is back.
//  Every "Connected" first cuts off what is still queued or speaking from before
//  (a "Retrying connection" repeat, "Disconnected"), which is stale by then.
//

import ConduitCallEngine
import Foundation

@MainActor
final class AgentCallHost: CallEngineDelegate {
    private let repository: AgentRepository
    private let keychain: KeychainStoring
    private let announcer: SpokenStateAnnouncing
    private let missedCallNotifier: MissedCallNotifying
    private let interactionDonor: CallInteractionDonating
    private let transportFactory: (TransportKind) -> CallTransport
    private let pairingResolver: PairingResolving
    private let registrationSession: URLSession
    private let delay: DelayedAction
    /// The engine whose VoIP token `registerInbound(for:)` sends.
    weak var engine: CallEngine?
    private var registrationTask: Task<Void, Never>?
    /// The connection whose "Connected" the mic is withheld for, while it is. Only
    /// the completion of that phrase releases it, so one from an earlier connection
    /// or call changes nothing.
    private var connectSoundsID: UUID?
    /// The pending "Connecting" of an answered call; only that prompt's delay may
    /// speak it. Cleared when the connecting loop stops (connected, held, ended).
    private var connectingPromptID: UUID?
    /// Whether this call has said "Connecting": an answered call says it at most once.
    private var didPromptConnecting = false
    #if DEBUG
    /// DEBUG: where the delegate's view of each ring and call goes (the call trace,
    /// for the live environment's engine only).
    var trace: ((String) -> Void)?
    #endif

    init(
        repository: AgentRepository,
        keychain: KeychainStoring,
        announcer: SpokenStateAnnouncing,
        missedCallNotifier: MissedCallNotifying,
        interactionDonor: CallInteractionDonating = CallInteractionDonor(),
        transportFactory: @escaping (TransportKind) -> CallTransport,
        pairingResolver: @escaping PairingResolving = Agent.livePairingResolver,
        registrationSession: URLSession = .shared,
        delay: DelayedAction? = nil
    ) {
        self.repository = repository
        self.keychain = keychain
        self.announcer = announcer
        self.missedCallNotifier = missedCallNotifier
        self.interactionDonor = interactionDonor
        self.transportFactory = transportFactory
        self.pairingResolver = pairingResolver
        self.registrationSession = registrationSession
        self.delay = delay ?? { wait, action in
            Task { @MainActor in
                try? await Task.sleep(for: wait)
                action()
            }
        }
    }

    /// Runs an action on the main actor after a wait (real time unless injected;
    /// tests run it by hand).
    typealias DelayedAction = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

    /// How long an answered call may stay connecting before "Connecting" is said.
    static let connectingPromptDelay: Duration = .seconds(1)

    func target(
        for agent: Agent,
        inlineConnection: CallConnection? = nil,
        ringPreparation: RingPreparation = .none
    ) -> CallTarget {
        agent.callTarget(
            keychain: keychain,
            transportFactory: transportFactory,
            pairingResolver: pairingResolver,
            inlineConnection: inlineConnection,
            ringPreparation: ringPreparation
        )
    }

    func agent(id: UUID) -> Agent? {
        (try? repository.fetch(id: id)) ?? nil
    }

    // MARK: - CallEngineDelegate

    /// Allows whatever preparation the ring's push asks for: the sender is the
    /// user's own backend, which knows whether its agent waits for the answer. Not
    /// for a fixed room (direct mode) without inline credentials: its bot was never
    /// told whether this app sends `call-connected` (only pairing requests and the
    /// token registration carry `call_signals`), so it may greet on the device's
    /// join, and the device joins it only after the answer (`.credentials` at most).
    /// The engine still lowers `.media` to `.credentials` for a transport that cannot
    /// join while ringing.
    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? {
        let agent = agent(id: call.targetID)
        trace("""
        ring: call=\(call.callID) known=\(agent != nil) preconnect=\(call.requestedPreparation) \
        inline=\(call.connection != nil) transport=\(agent?.transportKind.rawValue ?? "-")
        """)
        return agent.map {
            let isFixedRoom = $0.pairingEndpoint == nil && call.connection == nil
            let allowed = isFixedRoom ? min(call.requestedPreparation, .credentials) : call.requestedPreparation
            return target(for: $0, inlineConnection: call.connection, ringPreparation: allowed)
        }
    }

    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState) {
        trace("state: \(old) -> \(new)")
        switch new {
        case .ended, .failed, .idle:
            connectingPromptID = nil
            announcer.stopNow()
            releaseMicAfterConnectSounds(engine)
        case .dialing, .incomingRinging:
            didPromptConnecting = false
        case .connecting, .connected, .reconnecting: break
        }
        guard old == .dialing, case .connecting = new,
              let id = engine.activeCall?.targetID, let agent = agent(id: id) else { return }
        // Teach Siri's calling domain that this contact is called via Conduit —
        // enables the bare "call <agent>" phrase (the mirror contact has no
        // phone number, so without donations Siri considers it uncallable).
        interactionDonor.donateOutgoingCall(to: agent)
    }

    func callEngine(
        _ engine: CallEngine,
        didChangeRingPreparationPhaseFrom old: RingPreparationPhase,
        to new: RingPreparationPhase
    ) {
        trace("ring preparation: \(old) -> \(new)")
    }

    func callEngine(_ engine: CallEngine, cue: CallCue) {
        trace("cue: \(cue)")
        switch cue {
        case .start(.connecting):
            if engine.activeCall?.direction == .incoming {
                // The user picked up: a ringback now would sound as if they were calling.
                promptConnectingIfStillConnecting()
            } else {
                // The engine keeps the mic closed while connecting, so the ringback
                // needs no withhold, and holds a placed call connecting until its
                // first tone is done.
                announcer.startRepeating(.connecting)
            }
        case .start(.retrying): announcer.startRepeating(.retrying)
        case .stop:
            connectingPromptID = nil
            announcer.stopRepeating()
        case .moment(.connected):
            // Answered with the agent there: the user is already on with it, so
            // nothing is said and nothing withheld; the engine sends call-connected
            // once CallKit has activated the audio.
            guard engine.activeCall?.wasReadyAtAnswer != true else { break }
            speakConnected(engine)
        case .moment(.reconnected):
            // No withhold: a reconnect's "Connected" that stalls (seen after a
            // LiveKit reconnect) must not leave the user with a dead mic, and the
            // agent overhearing one short phrase is the lesser problem.
            announcer.cutOffPending()
            announcer.announce(.connected)
        case .moment(.connectionLost): announcer.announce(.disconnected)
        // "Connected" will not follow until the resume, which withholds again.
        case .moment(.held): releaseMicAfterConnectSounds(engine)
        case .moment(.resumed): break
        @unknown default: break
        }
    }

    /// "Connected", with the mic withheld until it has played. Synchronous, so the
    /// withhold precedes the engine's mic command for this moment; the release opens
    /// the mic and tells the agent to start speaking.
    private func speakConnected(_ engine: CallEngine) {
        let id = withholdMicForConnectSounds(engine)
        announcer.cutOffPending()
        announcer.announce(.connected) { [weak self, weak engine] in
            guard let self, let engine, self.connectSoundsID == id else { return }
            self.releaseMicAfterConnectSounds(engine)
        }
    }

    /// Say "Connecting" once if the answered call is still connecting after
    /// `connectingPromptDelay`. The engine keeps the mic closed until the call is
    /// connected, so the agent cannot hear it.
    private func promptConnectingIfStillConnecting() {
        guard !didPromptConnecting else { return }
        let id = UUID()
        connectingPromptID = id
        delay(Self.connectingPromptDelay) { [weak self] in
            guard let self, self.connectingPromptID == id else { return }
            self.connectingPromptID = nil
            self.didPromptConnecting = true
            self.trace("spoken: connecting (answered, still connecting)")
            self.announcer.announce(.connecting)
        }
    }

    /// Keep the agent from hearing "Connected" through the mic.
    private func withholdMicForConnectSounds(_ engine: CallEngine) -> UUID {
        let id = UUID()
        connectSoundsID = id
        engine.setMicWithheld(true)
        return id
    }

    private func releaseMicAfterConnectSounds(_ engine: CallEngine) {
        guard connectSoundsID != nil else { return }
        connectSoundsID = nil
        engine.setMicWithheld(false)
    }

    func callEngine(_ engine: CallEngine, didFinish record: CallRecord) {
        trace("""
        record: \(record.direction) outcome=\(record.outcome) \
        failure=\(record.failureReason.map { "\($0)" } ?? "-") \
        missed=\(record.missedReason.map { "\($0)" } ?? "-") duration=\(record.duration)
        """)
        guard let agent = agent(id: record.targetID) else { return }
        repository.addCallLogEntry(CallLogEntry(
            agent: agent,
            direction: record.direction,
            startedAt: record.startedAt,
            duration: record.duration,
            outcome: record.outcome,
            transportKind: agent.transportKind,
            failureReason: record.failureReason,
            missedReason: record.missedReason
        ))
        do { try repository.save() }
        catch { Log.error(.call, "Failed to save call log: \(error)") }
        if let reason = record.missedReason {
            missedCallNotifier.notifyMissedCall(agentName: agent.name, reason: reason)
        }
    }

    func callEngine(_ engine: CallEngine, ringStatusBearerForTarget id: UUID) -> String? {
        guard let agent = agent(id: id) else { return nil }
        return (try? keychain.token(for: KeychainTokenRef(account: agent.keychainTokenRef))) ?? nil
    }

    func callEngine(_ engine: CallEngine, didUpdateVoIPPushToken token: Data) {
        registrationTask?.cancel()
        registrationTask = Task { [weak self] in await self?.registerToken(token) }
    }

    /// The engine's `voipPushToken` is nil from here until PushKit issues a new one,
    /// so nothing registers the dead token afterwards; this stops a registration
    /// pass still sending it. Servers drop it on APNs' 410, and the next token
    /// registers over it.
    func callEngineDidInvalidateVoIPPushToken(_ engine: CallEngine) {
        registrationTask?.cancel()
        trace("voip token: invalidated")
    }

    private func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
        trace?(line())
        #endif
    }

    // MARK: - VoIP token registration

    /// Test hook: await the registration pass a token update started.
    func awaitPendingRegistration() async {
        await registrationTask?.value
    }

    private func registerToken(_ token: Data) async {
        let agents = ((try? repository.fetchAll()) ?? []).filter { $0.inboundRegistrationURL != nil }
        for agent in agents {
            guard !Task.isCancelled else { return }
            await register(token: token, agent: agent)
        }
    }

    private func register(token: Data, agent: Agent) async {
        guard let endpoint = agent.inboundRegistrationURL else { return }
        let apiKey = (try? keychain.token(for: KeychainTokenRef(account: agent.keychainTokenRef))) ?? nil
        await PushTokenRegistrar.register(
            token: token.map { String(format: "%02x", $0) }.joined(),
            agentID: agent.id,
            displayName: agent.name,
            handle: agent.syntheticEmail,
            endpoint: endpoint,
            apiKey: apiKey ?? "",
            transport: agent.transportKind,
            session: registrationSession
        )
    }
}

// MARK: - InboundRegistering (registration on toggle-save, not just app launch)

extension AgentCallHost: InboundRegistering {
    func registerInbound(for agent: Agent) async {
        guard let token = engine?.voipPushToken, !token.isEmpty else { return }
        await register(token: token, agent: agent)
    }
}
