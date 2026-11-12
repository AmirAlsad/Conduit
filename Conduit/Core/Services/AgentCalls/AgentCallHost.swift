//
//  AgentCallHost.swift
//  Conduit
//
//  Conduit's side of the call engine: turns agents into call targets (allowing
//  the ring preparation each push asks for) and reacts to what the engine
//  reports — writing the call log, speaking the engine's cues (with the mic
//  withheld until a connect's ringback and "Connected" are done), donating outgoing
//  calls to Siri, posting missed-call notifications, supplying the API key that
//  authenticates ring-status receipts, and registering the device's VoIP token
//  with every agent that lets itself call the user. The
//  engine identifies calls only by target id; this looks the agent up, and a
//  target with no agent (unknown or deleted) records nothing.
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
    /// The engine whose VoIP token `registerInbound(for:)` sends.
    weak var engine: CallEngine?
    private var registrationTask: Task<Void, Never>?
    /// The connect whose sounds the mic is withheld for, while it is. Only the
    /// completion of that connect's "Connected" releases it, so one from an
    /// earlier connect or call changes nothing.
    private var connectSoundsID: UUID?
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
        registrationSession: URLSession = .shared
    ) {
        self.repository = repository
        self.keychain = keychain
        self.announcer = announcer
        self.missedCallNotifier = missedCallNotifier
        self.interactionDonor = interactionDonor
        self.transportFactory = transportFactory
        self.pairingResolver = pairingResolver
        self.registrationSession = registrationSession
    }

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
    /// user's own backend, which knows whether its agent waits for the answer. The
    /// engine still lowers `.media` to `.credentials` for a transport that cannot
    /// join while ringing.
    func callEngine(_ engine: CallEngine, targetForIncomingCall call: IncomingCall) -> CallTarget? {
        let agent = agent(id: call.targetID)
        trace("""
        ring: call=\(call.callID) known=\(agent != nil) preconnect=\(call.requestedPreparation) \
        inline=\(call.connection != nil) transport=\(agent?.transportKind.rawValue ?? "-")
        """)
        return agent.map {
            target(for: $0, inlineConnection: call.connection, ringPreparation: call.requestedPreparation)
        }
    }

    func callEngine(_ engine: CallEngine, didChangeStateFrom old: CallState, to new: CallState) {
        trace("state: \(old) -> \(new)")
        switch new {
        case .ended, .failed, .idle:
            announcer.stopNow()
            releaseMicAfterConnectSounds(engine)
        case .dialing, .incomingRinging, .connecting, .connected, .reconnecting: break
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
            withholdMicForConnectSounds(engine)
            announcer.startRepeating(.connecting)
        case .start(.retrying): announcer.startRepeating(.retrying)
        case .stop: announcer.stopRepeating()
        case .moment(.connected), .moment(.reconnected):
            // Also the first withhold for a pre-connected answer, which has no
            // connecting cue; synchronous, so it precedes the engine's mic command.
            let id = withholdMicForConnectSounds(engine)
            announcer.announce(.connected) { [weak self, weak engine] in
                guard let self, let engine, self.connectSoundsID == id else { return }
                self.releaseMicAfterConnectSounds(engine)
            }
        case .moment(.connectionLost): announcer.announce(.disconnected)
        // "Connected" will not follow until the resume, which withholds again.
        case .moment(.held): releaseMicAfterConnectSounds(engine)
        case .moment(.resumed): break
        @unknown default: break
        }
    }

    /// Keep the agent from hearing the ringback and "Connected" through the mic.
    @discardableResult
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
