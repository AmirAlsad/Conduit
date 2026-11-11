//
//  CallSessionCoordinator.swift
//  Conduit
//
//  The call state machine and the heart of the app: it orchestrates the CallKit
//  seam (`CallProviding`) and the transport seam (`CallTransport`), owns `CallState`,
//  and drives reconnection. It knows calls, not agents: the host hands it a
//  `CallTarget` and hears back through `CallEngineDelegate` (transitions, finished
//  calls, incoming-target resolution, receipt bearers). It depends only on
//  protocols, so the whole machine runs in the simulator against fakes.
//
//  AUDIO-SESSION OWNERSHIP INVARIANT: `transport.attachAudioSession()` is called
//  only once CallKit has activated the session — from `activate(_:)` (the
//  `providerDidActivate` callback), or when a transport is created after that
//  activation already happened — and the mic is never enabled before activation.
//  CallKit owns the session; the transport attaches to it.
//

import Foundation

@MainActor
@Observable
final class CallSessionCoordinator: CallProviderDelegate, AudioInterruptionObserverDelegate {

    // MARK: - Observed state (the InCall screen is a pure projection of these)

    private(set) var state: CallState = .idle
    private(set) var activeCall: ActiveCall?
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
    /// Set when the local user taps End (vs a remote hangup or a failure). The UI
    /// dismisses a user-ended call immediately with no terminal page; remote/failed
    /// terminals keep their page until Close. Cleared on reset.
    private(set) var endedByUser = false

    // MARK: - Dependencies

    @ObservationIgnored weak var delegate: CallEngineDelegate?

    private let callProvider: CallProviding
    private let interruptionObserver: AudioInterruptionObserving
    private let ringStatusReporter: RingStatusReporting
    private let policy: ReconnectionPolicy
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private let isPushToTalkEnabled: () -> Bool

    // MARK: - Live-call bookkeeping

    private var transport: CallTransport?
    /// The resolved target of the live call; its `connect` runs per attempt.
    private var currentTarget: CallTarget?
    /// Who this call's record is attributed to — set even when an incoming
    /// target is unknown, so the host can decide there is nothing to record.
    private var recordTargetID: UUID?
    private var activeCallID: UUID?
    private var callDirection: CallDirection = .outgoing
    /// Where to report this ring's terminal status, when the push asked for receipts.
    private var ringStatusURL: URL?
    private var callStartedAt: Date?
    private var firstConnectedAt: Date?
    private var reconnectAttempt = 0
    private var didApplyHandsFreeDefault = false
    private var eventTask: Task<Void, Never>?
    private(set) var reconnectTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?

    init(
        callProvider: CallProviding,
        interruptionObserver: AudioInterruptionObserving,
        ringStatusReporter: RingStatusReporting,
        policy: ReconnectionPolicy = .default,
        now: @escaping () -> Date,
        sleep: @escaping (Duration) async throws -> Void,
        isPushToTalkEnabled: @escaping () -> Bool
    ) {
        self.callProvider = callProvider
        self.interruptionObserver = interruptionObserver
        self.ringStatusReporter = ringStatusReporter
        self.policy = policy
        self.now = now
        self.sleep = sleep
        self.isPushToTalkEnabled = isPushToTalkEnabled
        callProvider.delegate = self
        interruptionObserver.delegate = self
    }

    // MARK: - Placing a call

    func placeCall(_ target: CallTarget) async {
        guard case .idle = state else {
            Log.warning(.call, "placeCall ignored; state is \(String(describing: state))")
            return
        }

        currentTarget = target
        recordTargetID = target.id
        activeCall = ActiveCall(targetID: target.id, displayName: target.displayName, direction: .outgoing)
        callDirection = .outgoing
        callStartedAt = now()
        transition(to: .dialing)
        interruptionObserver.startObserving()

        let id: UUID
        do {
            id = try await callProvider.startOutgoingCall(handle: callHandle(for: target), displayName: target.displayName)
        } catch {
            Log.error(.callkit, "startOutgoingCall failed: \(error)")
            fail(.unknown)
            return
        }
        // The user may have ended the call while CallKit was starting it. That end
        // already finished and recorded the call; don't leave the system holding
        // the call it just started, and don't join the room.
        guard case .dialing = state else {
            Log.info(.call, "Call ended while dialing; ending the started CallKit call")
            await callProvider.endCall(id)
            return
        }
        activeCallID = id
        callProvider.reportOutgoingCallConnecting(id)
        transition(to: .connecting)

        await connectTransport(for: target)
    }

    private func callHandle(for target: CallTarget) -> CallHandle {
        CallHandle(value: target.handle ?? CallTarget.defaultHandle(for: target.id))
    }

    // MARK: - Receiving a call (agent-initiated, via VoIP push)

    /// Report an incoming call to CallKit and ring. The transport doesn't connect
    /// until the user answers (`answer()`), so this only resolves the target and
    /// reports — its credentials (inline or via the host) are used on answer.
    func receiveCall(_ payload: IncomingCallPayload) async {
        let incoming = IncomingCall(
            callID: payload.callID,
            targetID: payload.agentID,
            displayName: Self.unknownCallerName,
            handle: Self.unknownCallerHandle,
            connection: payload.inlineConnection
        )
        guard case .idle = state else {
            // One call at a time — but iOS terminates the app (killing the active
            // call's media) if a VoIP push doesn't report an incoming call. Report
            // under the push's own id, end it immediately, and record the missed ring
            // without touching the active call's state.
            Log.warning(.call, "Busy on VoIP push; reporting call \(payload.callID) and ending it")
            let busyTarget = delegate?.callEngine(self, targetForIncomingCall: incoming)
            try? await callProvider.reportIncomingCall(
                id: payload.callID,
                handle: busyTarget.map(callHandle(for:)) ?? CallHandle(value: incoming.handle),
                displayName: busyTarget?.displayName ?? incoming.displayName
            )
            callProvider.reportCallEnded(payload.callID, reason: .unanswered)
            delegate?.callEngine(self, didFinish: CallRecord(
                targetID: payload.agentID,
                direction: .incoming,
                startedAt: now(),
                duration: 0,
                outcome: .noAnswer,
                missedReason: .busy
            ))
            if let url = payload.statusURL {
                reportRingStatus(.busy, callID: payload.callID, endpoint: url, targetID: payload.agentID)
            }
            return
        }

        let target = delegate?.callEngine(self, targetForIncomingCall: incoming)
        activeCallID = payload.callID
        currentTarget = target
        recordTargetID = payload.agentID
        activeCall = target.map { ActiveCall(targetID: $0.id, displayName: $0.displayName, direction: .incoming) }
        callDirection = .incoming
        callStartedAt = now()
        ringStatusURL = payload.statusURL
        transition(to: .incomingRinging)
        interruptionObserver.startObserving()

        // PushKit requires reporting the call this run loop even if the target is
        // unknown — report under a generic handle, then fail gracefully.
        do {
            try await callProvider.reportIncomingCall(
                id: payload.callID,
                handle: target.map(callHandle(for:)) ?? CallHandle(value: incoming.handle),
                displayName: target?.displayName ?? incoming.displayName
            )
        } catch IncomingCallReportError.filteredByFocus {
            // The system suppressed the ring (Focus/DND) — a missed call, not a
            // failure. Record it and return to idle so the next push rings normally.
            Log.info(.call, "Incoming call filtered by Focus; recording as missed")
            interruptionObserver.stopObserving()
            finish(outcome: .noAnswer, missedReason: .filteredByFocus)
            if let url = ringStatusURL {
                reportRingStatus(.suppressedByFocus, callID: payload.callID, endpoint: url, targetID: payload.agentID)
            }
            resetState()
            return
        } catch {
            Log.error(.callkit, "reportIncomingCall failed: \(error)")
            fail(.unknown)
            return
        }

        if target == nil {
            Log.error(.call, "Incoming call for unknown target \(payload.agentID)")
            fail(.unknown)
        }
    }

    private static let unknownCallerName = "Agent"
    private static let unknownCallerHandle = "agent"

    /// The user answered (from the system UI). Connect the transport with the
    /// resolved target's credentials (the push's inline room, or the host's own).
    func answer() async {
        guard case .incomingRinging = state, let target = currentTarget else { return }
        transition(to: .connecting)
        // Answering is the ring's terminal status — the receipt fires here whether
        // or not the transport subsequently connects.
        if let url = ringStatusURL, let id = activeCallID {
            reportRingStatus(.answered, callID: id, endpoint: url, targetID: target.id)
            ringStatusURL = nil
        }
        await connectTransport(for: target)
    }

    /// Fire-and-forget receipt to the server that rang us, authenticated with the
    /// bearer the host supplies for the target (omitted when it has none).
    private func reportRingStatus(_ status: RingStatus, callID: UUID, endpoint: URL, targetID: UUID?) {
        let apiKey = targetID.flatMap { delegate?.callEngine(self, ringStatusBearerForTarget: $0) }
        ringStatusReporter.report(status, callID: callID, endpoint: endpoint, apiKey: apiKey ?? "")
    }

    /// Create and subscribe the transport, then resolve credentials and connect.
    /// Shared by `placeCall` and `answer`. The transport exists before the
    /// credential fetch so a CallKit activation landing mid-fetch still reaches
    /// `attachAudioSession()` (see potential_skills/callkit.md).
    private func connectTransport(for target: CallTarget) async {
        let transport = target.makeTransport()
        self.transport = transport
        subscribe(to: transport)
        // CallKit can activate before the transport exists (while dialing, or
        // before `answer()` runs); that activation found no transport to attach.
        if isAudioActivated { await transport.attachAudioSession() }

        do {
            let connection = try await target.connect()
            // The call may have ended while credentials were in flight.
            guard self.transport === transport else { return }
            try await transport.connect(connection)
        } catch {
            Log.error(.transport, "connect failed: \(error)")
            // `connect` can resolve LATE — after an event already failed this call and
            // the user reset to idle (or started another call). Failing again would
            // re-enter `.failed` and re-present the call screen. Ignore unless this is
            // still the live transport.
            guard self.transport === transport else { return }
            fail((error as? TransportError) == .authenticationFailed ? .badToken : .transportError)
        }
    }

    private func subscribe(to transport: CallTransport) {
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
            transition(to: .connected(since: start))
            // Incoming calls are marked connected to CallKit by fulfilling the answer
            // action; only outgoing calls report connected here.
            if callDirection == .outgoing, let id = activeCallID {
                callProvider.reportOutgoingCallConnected(id)
            }
            applyMicIfActivated()
            Task { [weak self] in await self?.updateAudioDevices() }
            Log.info(.call, "Connected")

        case .reconnecting:
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            transition(to: .connected(since: firstConnectedAt ?? now()))
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
        transition(to: .reconnecting(attempt: reconnectAttempt))
    }

    private func scheduleReconnect() {
        let next = reconnectAttempt + 1
        guard policy.canAttempt(next) else {
            Log.warning(.call, "Reconnection budget exhausted after \(reconnectAttempt) attempts")
            fail(.lostConnection)
            return
        }
        reconnectAttempt = next

        transition(to: .reconnecting(attempt: reconnectAttempt))

        let delay = policy.delay(forAttempt: reconnectAttempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await self?.sleep(delay)
            guard let self, !Task.isCancelled else { return }
            await self.retryConnect()
        }
    }

    private func retryConnect() async {
        guard let transport, let target = currentTarget else { return }
        // Success surfaces as a `.connected` event; a transport that reports the
        // failed attempt as a `.disconnected` event schedules the next attempt there.
        // A transport that instead throws is chained here, so the loop never stalls.
        // Both awaits can outlive the call: once it has ended, this attempt is inert.
        do {
            let connection = try await target.connect()
            guard self.transport === transport, !Task.isCancelled else { return }
            try await transport.connect(connection)
        } catch {
            Log.error(.transport, "Reconnect attempt failed: \(error)")
            guard self.transport === transport, !Task.isCancelled else { return }
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
        // Idempotent against our own End path, which already finished and reset (so
        // `activeCallID` is nil): only act while this id is still the live call.
        guard activeCallID == id else { return }
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

    /// Flip the user-ended flag synchronously so the UI can dismiss the in-call
    /// cover in the SAME (animation-disabled) transaction as the tap — no slide-down
    /// reveal. `endCall()` then does the actual teardown asynchronously.
    func markEndedByUser() {
        guard state.isActive, !state.isTerminal else { return }
        endedByUser = true
    }

    func endCall() async {
        guard state.isActive, !state.isTerminal else { return }
        // Mark this as a local user-end: the UI dismisses immediately with no
        // "Call Ended" page (presentation lives in RootTabView), while the state
        // still goes `.ended` (logged) per the coordinator contract. Going terminal
        // BEFORE the system round-trip also avoids the mid-`.connecting` race where a
        // teardown disconnect would be misread as `.failed`. `finishEnded` nils
        // `activeCallID`, so capture it first; the round-trip then no-ops on the
        // stale id (see `providerPerformEndCall`).
        endedByUser = true
        let id = activeCallID
        finishEnded()
        if let id { await callProvider.endCall(id) }
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

    #if DEBUG
    /// Project a connected call onto the in-call surface without a real transport,
    /// so its look can be screenshotted in the simulator. Drives only the observed
    /// state the view reads — no CallKit, no media, and no delegate callbacks.
    func debugPresentConnected(_ call: ActiveCall, secondsElapsed: TimeInterval = 154, botSpeaking: Bool = true) {
        activeCall = call
        callDirection = call.direction
        state = .connected(since: now().addingTimeInterval(-secondsElapsed))
        isBotSpeaking = botSpeaking
    }
    #endif

    private var micShouldBeOn: Bool {
        !isMuted && !isPushToTalkEnabled()
    }

    // MARK: - Terminal transitions

    private func fail(_ reason: CallFailureReason) {
        guard !state.isTerminal else { return }
        transition(to: .failed(reason))
        if let id = activeCallID { callProvider.reportCallEnded(id, reason: .failed) }
        finish(outcome: .failed, failureReason: reason)
        teardownTransport()
    }

    private func endRemote() {
        guard !state.isTerminal else { return }
        let connected = firstConnectedAt != nil
        transition(to: .ended(.completed))
        if let id = activeCallID { callProvider.reportCallEnded(id, reason: .remoteEnded) }
        finish(outcome: connected ? .completed : .noAnswer)
        teardownTransport()
    }

    /// The system already knows the call is ending (we requested it, or it told us),
    /// so this does not report back to CallKit. The terminal guard makes the real
    /// CallKit end → providerPerformEndCall round-trip idempotent (no double record).
    private func finishEnded() {
        guard !state.isTerminal else { return }
        let connected = firstConnectedAt != nil
        // An incoming call ended before it ever connected was declined; an outgoing
        // one was canceled.
        let outcome: CallOutcome = connected ? .completed
            : (callDirection == .incoming ? .declined : .canceled)
        if outcome == .declined, let url = ringStatusURL, let id = activeCallID {
            reportRingStatus(.declined, callID: id, endpoint: url, targetID: recordTargetID)
            ringStatusURL = nil
        }
        transition(to: .ended(outcome))
        finish(outcome: outcome)
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
        activeCall = nil
        currentTarget = nil
        recordTargetID = nil
        activeCallID = nil
        callDirection = .outgoing
        ringStatusURL = nil
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
        endedByUser = false
        transition(to: .idle)
    }

    /// Assign the state and tell the delegate. Callers set the transition's other
    /// fields first, so the delegate sees a consistent snapshot.
    private func transition(to new: CallState) {
        let old = state
        state = new
        guard old != new else { return }
        delegate?.callEngine(self, didChangeStateFrom: old, to: new)
    }

    private func finish(
        outcome: CallOutcome,
        failureReason: CallFailureReason? = nil,
        missedReason: MissedCallReason? = nil
    ) {
        guard let targetID = recordTargetID else { return }
        let started = callStartedAt ?? now()
        let duration = firstConnectedAt.map { max(0, now().timeIntervalSince($0)) } ?? 0
        delegate?.callEngine(self, didFinish: CallRecord(
            targetID: targetID,
            direction: callDirection,
            startedAt: started,
            duration: duration,
            outcome: outcome,
            failureReason: failureReason,
            missedReason: missedReason
        ))
    }
}
