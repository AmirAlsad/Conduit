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
final class CallSessionCoordinator: CallProviderDelegate, AudioInterruptionObserverDelegate {

    // MARK: - Observed state (the InCall screen is a pure projection of these)

    private(set) var state: CallState = .idle
    private(set) var activeAgent: Agent?
    private(set) var isMuted = false
    private(set) var isBotSpeaking = false
    private(set) var remoteAudioLevel: Float = 0
    /// Whether CallKit has activated the audio session for the live call.
    private(set) var isAudioActivated = false
    /// Whether another audio session (Siri, a phone call, navigation) is currently
    /// interrupting the call. Transient — the mic pauses while true.
    private(set) var isInterrupted = false
    /// Available audio routes and the active one, for the in-call route picker.
    private(set) var audioDevices: [AudioDeviceInfo] = []
    private(set) var selectedAudioDeviceID: String?

    // MARK: - Dependencies

    private let callProvider: CallProviding
    private let transportFactory: (TransportKind) -> Transport
    private let keychain: KeychainStoring
    private let repository: AgentRepository
    private let announcer: SpokenStateAnnouncing
    private let interruptionObserver: AudioInterruptionObserving
    private let missedCallNotifier: MissedCallNotifying
    private let policy: ReconnectionPolicy
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private let isPushToTalkEnabled: () -> Bool

    // MARK: - Live-call bookkeeping

    private var transport: Transport?
    private var currentConfig: TransportConfig?
    private var activeCallID: UUID?
    private var callDirection: CallDirection = .outgoing
    /// Inline room credentials from an incoming push, consumed when the user answers.
    private var pendingInlineCreds: PairingCredentials?
    private var callStartedAt: Date?
    private var firstConnectedAt: Date?
    private var reconnectAttempt = 0
    private var didApplyHandsFreeDefault = false
    private var eventTask: Task<Void, Never>?
    private(set) var reconnectTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?

    init(
        callProvider: CallProviding,
        transportFactory: @escaping (TransportKind) -> Transport,
        keychain: KeychainStoring,
        repository: AgentRepository,
        announcer: SpokenStateAnnouncing,
        interruptionObserver: AudioInterruptionObserving,
        missedCallNotifier: MissedCallNotifying,
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
        self.interruptionObserver = interruptionObserver
        self.missedCallNotifier = missedCallNotifier
        self.policy = policy
        self.now = now
        self.sleep = sleep
        self.isPushToTalkEnabled = isPushToTalkEnabled
        callProvider.delegate = self
        interruptionObserver.delegate = self
    }

    // MARK: - Placing a call

    func placeCall(_ agent: Agent) async {
        guard case .idle = state else {
            Log.warning(.call, "placeCall ignored; state is \(String(describing: state))")
            return
        }

        activeAgent = agent
        callDirection = .outgoing
        callStartedAt = now()
        state = .dialing
        interruptionObserver.startObserving()

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

        await connectTransport(for: agent)
    }

    // MARK: - Receiving a call (agent-initiated, via VoIP push)

    /// Report an incoming call to CallKit and ring. The transport doesn't connect
    /// until the user answers (`answer()`), so this only resolves the agent and
    /// reports — credentials (inline or via pairing) are used on answer.
    func receiveCall(_ payload: IncomingCallPayload) async {
        guard case .idle = state else {
            // One call at a time — but iOS terminates the app (killing the active
            // call's media) if a VoIP push doesn't report an incoming call. Report
            // under the push's own id, end it immediately, and log the missed ring
            // without touching the active call's state.
            Log.warning(.call, "Busy on VoIP push; reporting call \(payload.callID) and ending it")
            let busyAgent = (try? repository.fetch(id: payload.agentID)) ?? nil
            try? await callProvider.reportIncomingCall(
                id: payload.callID,
                handle: busyAgent?.callHandle ?? CallHandle(value: "agent"),
                displayName: busyAgent?.name ?? "Agent"
            )
            callProvider.reportCallEnded(payload.callID, reason: .unanswered)
            if let busyAgent {
                let entry = CallLogEntry(
                    agent: busyAgent,
                    direction: .incoming,
                    startedAt: now(),
                    duration: 0,
                    outcome: .noAnswer,
                    transportKind: busyAgent.transportKind
                )
                repository.addCallLogEntry(entry)
                try? repository.save()
                missedCallNotifier.notifyMissedCall(agentName: busyAgent.name)
            }
            return
        }

        let agent = (try? repository.fetch(id: payload.agentID)) ?? nil
        activeCallID = payload.callID
        activeAgent = agent
        callDirection = .incoming
        callStartedAt = now()
        pendingInlineCreds = payload.inlineCredentials
        state = .incomingRinging
        interruptionObserver.startObserving()

        // PushKit requires reporting the call this run loop even if the agent is
        // unknown — report under a generic handle, then fail gracefully.
        do {
            try await callProvider.reportIncomingCall(
                id: payload.callID,
                handle: agent?.callHandle ?? CallHandle(value: "agent"),
                displayName: agent?.name ?? "Agent"
            )
        } catch IncomingCallReportError.filteredByFocus {
            // The system suppressed the ring (Focus/DND) — a missed call, not a
            // failure. Log it, notify quietly, and return to idle so the next
            // push rings normally.
            Log.info(.call, "Incoming call filtered by Focus; logging as missed")
            interruptionObserver.stopObserving()
            writeLog(outcome: .noAnswer)
            if let agent { missedCallNotifier.notifyMissedCall(agentName: agent.name) }
            resetState()
            return
        } catch {
            Log.error(.callkit, "reportIncomingCall failed: \(error)")
            fail(.unknown)
            return
        }

        if agent == nil {
            Log.error(.call, "Incoming call for unknown agent \(payload.agentID)")
            fail(.unknown)
        }
    }

    /// The user answered (from the system UI). Connect the transport, preferring the
    /// push's inline credentials and falling back to the agent's pairing endpoint.
    func answer() async {
        guard case .incomingRinging = state, let agent = activeAgent else { return }
        state = .connecting
        announcer.startRepeating(.connecting)
        let creds = pendingInlineCreds
        pendingInlineCreds = nil
        await connectTransport(for: agent, inlineCreds: creds)
    }

    /// Build the transport config (inline push credentials win; otherwise the agent's
    /// own direct/pairing config) and connect. Shared by `placeCall` and `answer`.
    private func connectTransport(for agent: Agent, inlineCreds: PairingCredentials? = nil) async {
        let config: TransportConfig
        if let inlineCreds {
            // Credentials delivered in the push: join the room directly, no pairing.
            config = TransportConfig(
                kind: agent.transportKind,
                url: inlineCreds.roomURL,
                token: inlineCreds.token
            )
        } else {
            let token = loadToken(for: agent) ?? ""
            // Direct mode needs its room token; pairing mode authenticates with its API
            // key, but an endpoint may be open, so don't hard-require it.
            if token.isEmpty, agent.pairingEndpoint == nil {
                Log.error(.call, "No token for agent \(Log.redactEmail(agent.syntheticEmail))")
                fail(.badToken)
                return
            }
            config = TransportConfig(
                kind: agent.transportKind,
                url: agent.connectionURL,
                token: token,
                pairingEndpoint: agent.pairingEndpoint
            )
        }
        currentConfig = config

        let transport = transportFactory(agent.transportKind)
        self.transport = transport
        subscribe(to: transport)

        do {
            try await transport.connect(config)
        } catch {
            Log.error(.transport, "connect failed: \(error)")
            fail((error as? TransportError) == .authenticationFailed ? .badToken : .transportError)
        }
    }

    /// The secret for the path this call will take: the pairing API key when a
    /// pairing endpoint is set (it wins if both are configured), otherwise the
    /// direct-room token. Each lives under its own Keychain ref.
    private func loadToken(for agent: Agent) -> String? {
        let ref = agent.pairingEndpoint != nil
            ? KeychainTokenRef(account: agent.keychainTokenRef)
            : KeychainTokenRef(directTokenForAgentID: agent.id)
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

        case .audioDevicesChanged:
            Task { [weak self] in await self?.updateAudioDevices() }

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
            // Incoming calls are marked connected to CallKit by fulfilling the answer
            // action; only outgoing calls report connected here.
            if callDirection == .outgoing, let id = activeCallID {
                callProvider.reportOutgoingCallConnected(id)
            }
            announcer.stopRepeating()
            announcer.announce(.connected)
            applyMicIfActivated()
            Task { [weak self] in await self?.updateAudioDevices() }
            Log.info(.call, "Connected")

        case .reconnecting:
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            state = .connected(since: firstConnectedAt ?? now())
            announcer.stopRepeating()
            announcer.announce(.connected)
            applyMicIfActivated()
            Log.info(.call, "Reconnected")

        default:
            break
        }
    }

    /// Re-apply the mic state once connected — covers the case where CallKit
    /// activated the audio session before the transport finished connecting (so
    /// the `activate(_:)` call to `setMicEnabled` no-op'd on a not-yet-joined client).
    private func applyMicIfActivated() {
        guard isAudioActivated else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.transport?.setMicEnabled(self.micShouldBeOn)
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
        isAudioActivated = true
        await transport?.attachAudioSession()
        // Enabling the mic only takes effect once the transport is connected. If
        // CallKit activates BEFORE connect (e.g. a slow pairing fetch delays the
        // join), this is a no-op and the mic is (re)enabled in `handleConnected`.
        await transport?.setMicEnabled(micShouldBeOn)
        await refreshAudioDevices()
    }

    /// Hands-free default: prefer the loudspeaker when nothing external (car /
    /// Bluetooth / wired) is connected, so call audio isn't stuck on the quiet
    /// earpiece. Driven through the transport (an AVAudioSession override doesn't
    /// stick — the WebRTC SDK manages the session and reverts it). Runs once per
    /// call, after connect, when the device list is populated.
    private func applyHandsFreeDefaultIfNeeded() async {
        // Caller refreshes the device list first; bail until it's populated so a
        // later trigger (connect / devices-changed) can apply the default instead.
        guard !didApplyHandsFreeDefault, !audioDevices.isEmpty else { return }
        didApplyHandsFreeDefault = true

        let hasExternalRoute = audioDevices.contains {
            let kind = AudioRouteKind(deviceID: $0.id)
            return kind == .bluetooth || kind == .wired
        }
        guard !hasExternalRoute,
              let speaker = audioDevices.first(where: { AudioRouteKind(deviceID: $0.id) == .speaker })
        else { return }
        await transport?.setAudioDevice(speaker.id)
        await refreshAudioDevices()
    }

    func providerDidDeactivate(_ audioSession: AudioSessionActivating) {
        Log.info(.callkit, "Audio session deactivated")
        isAudioActivated = false
        Task { [weak self] in await self?.transport?.detachAudioSession() }
    }

    func providerPerformAnswerCall(_ id: UUID) {
        Log.info(.callkit, "System requested answer")
        Task { [weak self] in await self?.answer() }
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

    // MARK: - Audio interruptions (AudioInterruptionObserverDelegate)
    //
    // A transient takeover (Siri, a navigation prompt that can't mix, a real phone
    // call): pause the mic while interrupted and re-apply it on resume. We never
    // touch the audio session — CallKit owns it and re-fires `providerDidActivate`
    // when the interruption ends, so this and that activation are two unordered
    // edges; both re-apply mic state idempotently (see potential_skills/callkit.md).

    func audioInterruptionBegan() {
        guard state.isActive, !state.isTerminal else { return }
        Log.info(.call, "Call interrupted; pausing mic")
        isInterrupted = true
        Task { [weak self] in await self?.transport?.setMicEnabled(false) }
    }

    func audioInterruptionEnded(shouldResume: Bool) {
        guard isInterrupted else { return }
        Log.info(.call, "Interruption ended; resume=\(shouldResume)")
        isInterrupted = false
        guard shouldResume else { return }
        applyMicIfActivated()
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

    // MARK: - Audio route (driven through the transport so the SDK honors it)

    func selectAudioDevice(_ id: String) async {
        await transport?.setAudioDevice(id)
        await refreshAudioDevices()
    }

    private func refreshAudioDevices() async {
        audioDevices = await transport?.availableAudioDevices() ?? []
        selectedAudioDeviceID = await transport?.selectedAudioDevice()?.id
    }

    /// Refresh the route list (keeps the picker live) and apply the hands-free
    /// default once it's available. Called on connect and on device changes.
    private func updateAudioDevices() async {
        await refreshAudioDevices()
        await applyHandsFreeDefaultIfNeeded()
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
        // An incoming call ended before it ever connected was declined; an outgoing
        // one was canceled.
        let outcome: CallOutcome = connected ? .completed
            : (callDirection == .incoming ? .declined : .canceled)
        state = .ended(outcome)
        announcer.stopRepeating()
        writeLog(outcome: outcome)
        teardownTransport()
    }

    private func teardownTransport() {
        interruptionObserver.stopObserving()
        isInterrupted = false
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
        callDirection = .outgoing
        pendingInlineCreds = nil
        currentConfig = nil
        callStartedAt = nil
        firstConnectedAt = nil
        reconnectAttempt = 0
        isMuted = false
        isBotSpeaking = false
        remoteAudioLevel = 0
        isAudioActivated = false
        isInterrupted = false
        audioDevices = []
        selectedAudioDeviceID = nil
        didApplyHandsFreeDefault = false
    }

    private func writeLog(outcome: CallOutcome) {
        guard let agent = activeAgent else { return }
        let started = callStartedAt ?? now()
        let duration = firstConnectedAt.map { max(0, now().timeIntervalSince($0)) } ?? 0
        let entry = CallLogEntry(
            agent: agent,
            direction: callDirection,
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
