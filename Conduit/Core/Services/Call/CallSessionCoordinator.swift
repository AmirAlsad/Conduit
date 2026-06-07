//
//  CallSessionCoordinator.swift
//  Conduit
//
//  The call state machine and the heart of the app: it orchestrates the CallKit
//  seam (`CallProviding`) and the transport seam (`Transport`), owns `CallState`,
//  drives reconnection-with-spoken-state, and writes the call log. It depends only
//  on protocols, so the whole machine runs in the simulator against fakes.
//
//  AUDIO-SESSION OWNERSHIP INVARIANT: `transport.attachAudioSession()` is called
//  from exactly one place — `activate(_:)`, reached only via the CallKit
//  `providerDidActivate` callback — and the mic is never enabled before activation.
//  CallKit owns the session; the transport attaches to it.
//

import Foundation

@MainActor
@Observable
final class CallSessionCoordinator: CallProviderDelegate {

    // MARK: - Observed state (the InCall screen is a pure projection of these)

    private(set) var state: CallState = .idle
    private(set) var activeAgent: Agent?
    private(set) var isMuted = false
    private(set) var isBotSpeaking = false
    private(set) var remoteAudioLevel: Float = 0

    // MARK: - Dependencies

    private let callProvider: CallProviding
    private let transportFactory: (TransportKind) -> Transport
    private let keychain: KeychainStoring
    private let repository: AgentRepository
    private let announcer: SpokenStateAnnouncing
    private let policy: ReconnectionPolicy
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private let isPushToTalkEnabled: () -> Bool

    // MARK: - Live-call bookkeeping

    private var transport: Transport?
    private var currentConfig: TransportConfig?
    private var activeCallID: UUID?
    private var callStartedAt: Date?
    private var firstConnectedAt: Date?
    private var reconnectAttempt = 0
    private var eventTask: Task<Void, Never>?
    private(set) var reconnectTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?

    init(
        callProvider: CallProviding,
        transportFactory: @escaping (TransportKind) -> Transport,
        keychain: KeychainStoring,
        repository: AgentRepository,
        announcer: SpokenStateAnnouncing,
        policy: ReconnectionPolicy = .default,
        now: @escaping () -> Date,
        sleep: @escaping (Duration) async throws -> Void,
        isPushToTalkEnabled: @escaping () -> Bool
    ) {
        self.callProvider = callProvider
        self.transportFactory = transportFactory
        self.keychain = keychain
        self.repository = repository
        self.announcer = announcer
        self.policy = policy
        self.now = now
        self.sleep = sleep
        self.isPushToTalkEnabled = isPushToTalkEnabled
        callProvider.delegate = self
    }

    // MARK: - Placing a call

    func placeCall(_ agent: Agent) async {
        guard case .idle = state else {
            Log.warning(.call, "placeCall ignored; state is \(String(describing: state))")
            return
        }

        activeAgent = agent
        callStartedAt = now()
        state = .dialing

        let id: UUID
        do {
            id = try await callProvider.startOutgoingCall(handle: agent.callHandle, displayName: agent.name)
        } catch {
            Log.error(.callkit, "startOutgoingCall failed: \(error)")
            fail(.unknown)
            return
        }
        activeCallID = id
        callProvider.reportOutgoingCallConnecting(id)
        state = .connecting
        announcer.startRepeating(.connecting)

        guard let token = loadToken(for: agent) else {
            Log.error(.call, "No token for agent \(Log.redactEmail(agent.syntheticEmail))")
            fail(.badToken)
            return
        }

        let config = TransportConfig(
            kind: agent.transportKind,
            url: agent.connectionURL,
            token: token,
            pairingEndpoint: agent.pairingEndpoint
        )
        currentConfig = config

        let transport = transportFactory(agent.transportKind)
        self.transport = transport
        subscribe(to: transport)

        do {
            try await transport.connect(config)
        } catch {
            Log.error(.transport, "connect failed: \(error)")
            fail(.transportError)
        }
    }

    private func loadToken(for agent: Agent) -> String? {
        let ref = KeychainTokenRef(account: agent.keychainTokenRef)
        let token = try? keychain.token(for: ref)
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    private func subscribe(to transport: Transport) {
        eventTask?.cancel()
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    // MARK: - Transport events (the transition table)

    func handle(_ event: TransportEvent) {
        switch event {
        case .connecting:
            break // already reflected by `.connecting` / `.reconnecting`

        case .connected:
            handleConnected()

        case .reconnecting:
            // The transport is self-healing; reflect it without driving our own loop.
            if case .connected = state { enterReconnectingDisplay() }

        case .disconnected(let reason):
            handleDisconnect(reason)

        case .botStartedSpeaking:
            isBotSpeaking = true

        case .botStoppedSpeaking:
            isBotSpeaking = false

        case .userStartedSpeaking, .userStoppedSpeaking:
            break

        case .remoteAudioLevel(let level):
            remoteAudioLevel = level

        case .error(let error):
            handleError(error)
        }
    }

    private func handleConnected() {
        switch state {
        case .connecting:
            let start = now()
            firstConnectedAt = start
            state = .connected(since: start)
            if let id = activeCallID { callProvider.reportOutgoingCallConnected(id) }
            announcer.stopRepeating()
            announcer.announce(.connected)
            Log.info(.call, "Connected")

        case .reconnecting:
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            state = .connected(since: firstConnectedAt ?? now())
            announcer.stopRepeating()
            announcer.announce(.connected)
            Log.info(.call, "Reconnected")

        default:
            break
        }
    }

    private func handleDisconnect(_ reason: TransportDisconnectReason) {
        switch reason {
        case .requestedByUser:
            break // our own teardown drives the terminal state

        case .authFailed:
            fail(.badToken)

        case .botLeft:
            endRemote()

        case .networkDropped, .unknown:
            guard state.isActive, !state.isTerminal else { return }
            // A call that never connected has nothing to reconnect to; fail rather
            // than loop. Reconnection is for mid-call drops (the driving case).
            if firstConnectedAt == nil {
                fail(.transportError)
            } else {
                scheduleReconnect()
            }
        }
    }

    private func handleError(_ error: TransportError) {
        switch state {
        case .connecting:
            fail(error == .authenticationFailed ? .badToken : .transportError)
        default:
            Log.error(.transport, "Transport error during call: \(error)")
        }
    }

    // MARK: - Reconnection (event-driven; each drop is one attempt)

    /// Display-only response to a transport that is self-healing. It does NOT count
    /// against the reconnection budget or schedule our own retry — the budget is
    /// owned solely by `scheduleReconnect` (driven by `.disconnected`). The transport
    /// must follow a `.reconnecting` with a `.connected` or `.disconnected`.
    private func enterReconnectingDisplay() {
        state = .reconnecting(attempt: reconnectAttempt)
        announcer.announce(.disconnected)
        announcer.startRepeating(.retrying)
    }

    private func scheduleReconnect() {
        let next = reconnectAttempt + 1
        guard policy.canAttempt(next) else {
            Log.warning(.call, "Reconnection budget exhausted after \(reconnectAttempt) attempts")
            fail(.lostConnection)
            return
        }
        reconnectAttempt = next

        state = .reconnecting(attempt: reconnectAttempt)
        if reconnectAttempt == 1 {
            announcer.announce(.disconnected)
            announcer.startRepeating(.retrying)
        }

        let delay = policy.delay(forAttempt: reconnectAttempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await self?.sleep(delay)
            guard let self, !Task.isCancelled else { return }
            await self.retryConnect()
        }
    }

    private func retryConnect() async {
        guard let transport, let config = currentConfig else { return }
        // Success surfaces as a `.connected` event; a transport that reports the
        // failed attempt as a `.disconnected` event schedules the next attempt there.
        // A transport that instead throws is chained here, so the loop never stalls.
        do {
            try await transport.connect(config)
        } catch {
            Log.error(.transport, "Reconnect attempt failed: \(error)")
            scheduleReconnect()
        }
    }

    /// Test hook: await the in-flight reconnection attempt.
    func awaitPendingReconnect() async {
        await reconnectTask?.value
    }

    // MARK: - CallKit audio-session handshake (CallProviderDelegate)

    func providerDidActivate(_ audioSession: AudioSessionActivating) {
        Log.info(.callkit, "Audio session activated")
        activationTask = Task { [weak self] in await self?.activate(audioSession) }
    }

    /// Test hook: await the in-flight audio-session activation.
    func awaitPendingActivation() async {
        await activationTask?.value
    }

    /// Attach media to the CallKit-activated session. THE ONLY place media attaches.
    func activate(_ audioSession: AudioSessionActivating) async {
        // Route decision (hands-free default): force speaker only when no external
        // route is present, so we never yank audio off a connected car/Bluetooth.
        do {
            if !audioSession.hasExternalAudioRoute {
                try audioSession.overrideOutputToSpeaker()
            }
        } catch {
            Log.error(.audio, "Output route override failed: \(error)")
        }
        await transport?.attachAudioSession()
        await transport?.setMicEnabled(micShouldBeOn)
    }

    func providerDidDeactivate(_ audioSession: AudioSessionActivating) {
        Log.info(.callkit, "Audio session deactivated")
        Task { [weak self] in await self?.transport?.detachAudioSession() }
    }

    func providerPerformEndCall(_ id: UUID) {
        Log.info(.callkit, "System requested end call")
        finishEnded()
    }

    func providerPerformSetMuted(_ id: UUID, muted: Bool) {
        isMuted = muted
        Task { [weak self] in await self?.transport?.setMicEnabled(self?.micShouldBeOn ?? false) }
    }

    func providerWasReset() {
        Log.warning(.callkit, "Provider reset; tearing down call")
        teardownTransport()
        resetState()
    }

    // MARK: - User-initiated controls

    func endCall() async {
        guard state.isActive, !state.isTerminal else { return }
        // Request the system end; the real provider round-trips through
        // providerPerformEndCall, which the terminal guard makes idempotent.
        if let id = activeCallID { await callProvider.endCall(id) }
        finishEnded()
    }

    func setMuted(_ muted: Bool) async {
        isMuted = muted
        await transport?.setMicEnabled(micShouldBeOn)
        if let id = activeCallID { await callProvider.setMuted(id, muted: muted) }
    }

    /// Push-to-talk: open the mic only while the button is held (PTT mode only).
    func setPushToTalkActive(_ active: Bool) async {
        guard isPushToTalkEnabled() else { return }
        await transport?.setMicEnabled(active)
    }

    /// Return to idle after a terminal state (called by the UI on dismiss).
    func reset() {
        guard state.isTerminal else { return }
        resetState()
    }

    private var micShouldBeOn: Bool {
        !isMuted && !isPushToTalkEnabled()
    }

    // MARK: - Terminal transitions

    private func fail(_ reason: CallFailureReason) {
        guard !state.isTerminal else { return }
        state = .failed(reason)
        announcer.stopRepeating()
        if let id = activeCallID { callProvider.reportCallEnded(id, reason: .failed) }
        writeLog(outcome: .failed)
        teardownTransport()
    }

    private func endRemote() {
        guard !state.isTerminal else { return }
        let connected = firstConnectedAt != nil
        state = .ended(.completed)
        announcer.stopRepeating()
        if let id = activeCallID { callProvider.reportCallEnded(id, reason: .remoteEnded) }
        writeLog(outcome: connected ? .completed : .noAnswer)
        teardownTransport()
    }

    /// The system already knows the call is ending (we requested it, or it told us),
    /// so this does not report back to CallKit. The terminal guard makes the real
    /// CallKit end → providerPerformEndCall round-trip idempotent (no double log).
    private func finishEnded() {
        guard !state.isTerminal else { return }
        let connected = firstConnectedAt != nil
        state = .ended(connected ? .completed : .canceled)
        announcer.stopRepeating()
        writeLog(outcome: connected ? .completed : .canceled)
        teardownTransport()
    }

    private func teardownTransport() {
        reconnectTask?.cancel()
        reconnectTask = nil
        eventTask?.cancel()
        eventTask = nil
        activeCallID = nil
        let outgoing = transport
        transport = nil
        Task {
            await outgoing?.detachAudioSession()
            await outgoing?.disconnect()
        }
    }

    private func resetState() {
        state = .idle
        activeAgent = nil
        activeCallID = nil
        currentConfig = nil
        callStartedAt = nil
        firstConnectedAt = nil
        reconnectAttempt = 0
        isMuted = false
        isBotSpeaking = false
        remoteAudioLevel = 0
    }

    private func writeLog(outcome: CallOutcome) {
        guard let agent = activeAgent else { return }
        let started = callStartedAt ?? now()
        let duration = firstConnectedAt.map { max(0, now().timeIntervalSince($0)) } ?? 0
        let entry = CallLogEntry(
            agent: agent,
            direction: .outgoing,
            startedAt: started,
            duration: duration,
            outcome: outcome,
            transportKind: agent.transportKind
        )
        repository.addCallLogEntry(entry)
        do { try repository.save() }
        catch { Log.error(.call, "Failed to save call log: \(error)") }
    }
}
