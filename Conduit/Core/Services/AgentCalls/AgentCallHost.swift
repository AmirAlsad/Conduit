//
//  AgentCallHost.swift
//  Conduit
//
//  Conduit's side of the call engine: turns agents into call targets and reacts
//  to what the engine reports — writing the call log, speaking connection state,
//  donating outgoing calls to Siri, posting missed-call notifications, and
//  supplying the API key that authenticates ring-status receipts. The engine
//  identifies calls only by target id; this looks the agent up, and a target
//  with no agent (unknown or deleted) records nothing.
//

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

    init(
        repository: AgentRepository,
        keychain: KeychainStoring,
        announcer: SpokenStateAnnouncing,
        missedCallNotifier: MissedCallNotifying,
        interactionDonor: CallInteractionDonating = CallInteractionDonor(),
        transportFactory: @escaping (TransportKind) -> CallTransport,
        pairingResolver: @escaping PairingResolving = Agent.livePairingResolver
    ) {
        self.repository = repository
        self.keychain = keychain
        self.announcer = announcer
        self.missedCallNotifier = missedCallNotifier
        self.interactionDonor = interactionDonor
        self.transportFactory = transportFactory
        self.pairingResolver = pairingResolver
    }

    func target(for agent: Agent, inlineConnection: CallConnection? = nil) -> CallTarget {
        agent.callTarget(
            keychain: keychain,
            transportFactory: transportFactory,
            pairingResolver: pairingResolver,
            inlineConnection: inlineConnection
        )
    }

    func agent(id: UUID) -> Agent? {
        (try? repository.fetch(id: id)) ?? nil
    }

    // MARK: - CallEngineDelegate

    func callEngine(_ engine: CallSessionCoordinator, targetForIncomingCall call: IncomingCall) -> CallTarget? {
        agent(id: call.targetID).map { target(for: $0, inlineConnection: call.connection) }
    }

    func callEngine(_ engine: CallSessionCoordinator, didChangeStateFrom old: CallState, to new: CallState) {
        switch new {
        case .connecting:
            announcer.startRepeating(.connecting)
            if old == .dialing, let id = engine.activeCall?.targetID, let agent = agent(id: id) {
                // Teach Siri's calling domain that this contact is called via Conduit —
                // enables the bare "call <agent>" phrase (the mirror contact has no
                // phone number, so without donations Siri considers it uncallable).
                interactionDonor.donateOutgoingCall(to: agent)
            }
        case .connected:
            announcer.stopRepeating()
            announcer.announce(.connected)
        case .reconnecting(let attempt):
            // Cue the drop once: on leaving `.connected` (a self-heal or the first
            // app retry), or on the first app retry after a self-heal display.
            var fromConnected = false
            if case .connected = old { fromConnected = true }
            if fromConnected || attempt == 1 {
                announcer.announce(.disconnected)
                announcer.startRepeating(.retrying)
            }
        case .ended, .failed:
            announcer.stopRepeating()
        case .idle, .incomingRinging, .dialing:
            break
        }
    }

    func callEngine(_ engine: CallSessionCoordinator, didFinish record: CallRecord) {
        guard let agent = agent(id: record.targetID) else { return }
        repository.addCallLogEntry(CallLogEntry(
            agent: agent,
            direction: record.direction,
            startedAt: record.startedAt,
            duration: record.duration,
            outcome: record.outcome,
            transportKind: agent.transportKind,
            failureReason: record.failureReason
        ))
        do { try repository.save() }
        catch { Log.error(.call, "Failed to save call log: \(error)") }
        if record.missedReason != nil {
            missedCallNotifier.notifyMissedCall(agentName: agent.name)
        }
    }

    func callEngine(_ engine: CallSessionCoordinator, ringStatusBearerForTarget id: UUID) -> String? {
        guard let agent = agent(id: id) else { return nil }
        return (try? keychain.token(for: KeychainTokenRef(account: agent.keychainTokenRef))) ?? nil
    }
}
