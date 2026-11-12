//
//  PipecatSmallWebRTCTransport.swift
//  Conduit
//
//  The SmallWebRTC transport: peer-to-peer WebRTC straight to the user's own
//  Pipecat server — no Daily/LiveKit cloud. Wraps the Pipecat iOS client
//  (`PipecatClient` + the package's `SmallWebRTCTransport`) behind Conduit's
//  `CallTransport` protocol, mirroring PipecatDailyTransport: the SDK POSTs our SDP
//  offer to the server's offer URL (bearer-authed), PATCHes trickle-ICE to the
//  same URL, and carries RTVI over a data channel. Media is UDP, so this only
//  reaches servers the device can hit directly (LAN / self-hosted).
//
//  Named `PipecatSmallWebRTCTransport` to avoid colliding with the SDK's own
//  `SmallWebRTCTransport`.
//
//  Audio-session note: the SDK configures `AVAudioSession` itself (category,
//  mode, port overrides) with no manual-audio gate, so — like Daily — we join
//  with the mic DISABLED and only enable capture via `setMicEnabled`, which the
//  engine calls after CallKit activation. For the same reason it cannot connect
//  while a call rings (`canConnectWhileRinging` is false): its connect would
//  configure the session under the ringtone.
//
//  Route: with no preferred device the SDK configures the session for video chat,
//  which iOS plays on the loudspeaker, at the start of every join and after every
//  route change. So the transport keeps a call on the route it starts on: it tells
//  the SDK, through its own device API (`updateMic`), to prefer the route read at
//  the first attach, or the engine's request, which wins; a new client is told
//  before its join, which the SDK then applies from its first configuration. See
//  `SmallWebRTCAudioRouteGate`. Nothing here sets the audio session itself.
//
//  Hold: the SDK exposes no control over the agent's playout (its peer
//  connection and remote track are internal), so `detachAudioSession` can stop
//  capture but not playout. A held call stays silent only because the agent
//  honours `call-held`, which `send(_:)` delivers.
//
//  Call-control signals and the end-call signal travel as RTVI client messages
//  over the data channel, in the envelope the package's Daily adapter uses.
//
//  Attempts: `SmallWebRTCConnectionGate` decides what each connect attempt reports
//  and what a connect does with a session that is still up: only a live, ready
//  attempt is reported `.connected` again; anything else still up is taken over
//  (left without the end-call signal, its client released, a new client joins).
//
//  Joins are the transport's own: the SDK's `connect` runs in a task the transport
//  keeps (`SmallWebRTCJoin`). Of overlapping connects, the newest owns the transport
//  (`SmallWebRTCConnectLedger`): it takes the earlier one's session over, and the
//  earlier connect returns at once by throwing, touching nothing. `disconnect()`
//  lets a join in flight finish (within `joinSettleBound`) before it signals and
//  leaves, so the agent the join's offer started is told the call is over. A join
//  that cannot finish in that bound has its peer connection closed; the SDK then
//  never completes its connect (it waits for a data channel that will not open), and
//  the server's own connection timeout ends that agent. `disconnect()` releases the
//  client, so a later connect builds a new one.
//
//  Errors: every connect error is `.connectionFailed`. The SDK's HTTP error for a
//  rejected offer carries only a message, no status code, so a 401 cannot be told
//  apart without matching text, and a wrong guess now ends a reconnecting call as a
//  bad token. A rejected API key is caught exactly one step earlier, by pairing.
//

import AVFoundation
import ConduitCallEngine
import Foundation
import PipecatClientIOS
import PipecatClientIOSSmallWebrtc

@MainActor
final class PipecatSmallWebRTCTransport: CallTransport {
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    /// A Pipecat client and the mapper that is its delegate (`PipecatClient.delegate`
    /// is weak, so the session keeps the mapper alive).
    private struct Session {
        let client: PipecatClient
        let events: SmallWebRTCEventMapper
    }

    private var session: Session?
    /// The SDK connect in flight on `session`.
    private var join: SmallWebRTCJoin?
    private var ledger = SmallWebRTCConnectLedger()
    private var routes = SmallWebRTCAudioRouteGate()
    /// The giving of preferred-device changes to the SDK in progress.
    private var routeApplication: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    private func makeSession() -> Session {
        // Join with the mic disabled; capture is enabled only on CallKit activation
        // (via setMicEnabled), preserving the audio-session-ownership invariant.
        let client = PipecatClient(
            options: PipecatClientOptions(
                transport: PipecatClientIOSSmallWebrtc.SmallWebRTCTransport(),
                enableMic: false,
                enableCam: false
            )
        )
        let events = SmallWebRTCEventMapper(continuation: continuation)
        client.delegate = events
        events.onAvailableMics = { [weak self, weak events] ids in
            guard let self, let events, self.session?.events === events else { return }
            self.audioDevicesDidChange(ids)
        }
        routes.sessionDidReset()
        return Session(client: client, events: events)
    }

    // MARK: - CallTransport

    nonisolated var canConnectWhileRinging: Bool { false }

    func connect(_ connection: CallConnection) async throws {
        let ticket = ledger.connectDidBegin()
        var session = self.session ?? makeSession()
        self.session = session
        switch session.events.gate.plan(for: phase(of: session)) {
        case .join:
            break
        case .reportConnected:
            Log.info(.transport, "SmallWebRTC connect: the session is up and its agent ready; reporting it connected")
            if let event = session.events.gate.reconfirmConnected() { continuation.yield(event) }
            return
        case .takeOver:
            Log.warning(.transport, "SmallWebRTC connect: taking over a session that is not ready (\(session.client.state)); joining with a new client")
            let stale = session
            let staleJoin = join
            join = nil
            session = makeSession()
            self.session = session
            staleJoin?.abandon()
            await Self.retire(stale)
            try checkStanding(of: ticket, while: "taking a session over")
        }

        let routeBeforeJoin = Self.readOutputPort()
        routes.joinWillStart(activeRoute: routeBeforeJoin.flatMap(SmallWebRTCAudioRoute.init(outputPort:)))
        Self.traceRoute("join: route \(routeBeforeJoin?.rawValue ?? "no output") -> preferred audio device \(Self.describe(routes.wanted)) (\(routes.wantedReason))")
        await applyRoute().value
        try checkStanding(of: ticket, while: "giving the SDK its audio route")

        session.events.gate.connectDidStart()
        // A pairing agent's connection is the offer URL plus a short-lived bearer
        // for it — the engine key itself never rides the offer leg. Each engine
        // retry re-pairs and lands here with a fresh offer, which spawns a fresh
        // bot server-side (context resets). The SDK copies these headers onto both
        // the offer POST and the trickle-ICE PATCH.
        let headers: [[String: String]] = connection.token.map { [["Authorization": "Bearer \($0)"]] } ?? []
        let params = SmallWebRTCTransportConnectionParams(
            webrtcRequestParams: APIRequest(endpoint: connection.url, headers: headers)
        )
        let pending = SmallWebRTCJoin(client: session.client, params: params)
        join = pending
        // The caller cancelling its connect ends this attempt, and the join stays
        // recorded: the next connect takes it over, and a disconnect lets it finish
        // to tell its agent the call is over.
        let outcome = await withTaskCancellationHandler {
            await pending.outcomeForConnect()
        } onCancel: {
            Task { @MainActor in pending.abandon() }
        }
        try checkStanding(of: ticket, while: "joining")
        switch outcome {
        case .joined:
            join = nil
            Self.traceRoute("joined: SDK selected \(session.client.selectedMic?.id.id ?? "none"), route \(Self.readOutputPort()?.rawValue ?? "no output")")
        case .failed(let error):
            join = nil
            session.events.gate.connectDidFail()
            Log.error(.transport, "SmallWebRTC connect failed: \(error)")
            throw TransportError.connectionFailed(String(describing: error))
        case .abandoned:
            session.events.gate.connectDidFail()
            Log.info(.transport, "SmallWebRTC connect cancelled while joining")
            throw CancellationError()
        }
    }

    /// Throws when a newer connect or the host's `disconnect()` began after this
    /// connect, which then owns nothing any more.
    private func checkStanding(of ticket: SmallWebRTCConnectLedger.Ticket, while step: String) throws {
        switch ledger.standing(of: ticket) {
        case .current:
            return
        case .superseded:
            Log.info(.transport, "SmallWebRTC connect: superseded by a newer connect while \(step)")
            throw TransportError.connectionFailed("SmallWebRTC connect superseded by a newer one")
        case .disconnected:
            Log.info(.transport, "SmallWebRTC connect: the host disconnected while \(step)")
            throw TransportError.connectionFailed("SmallWebRTC transport was disconnected while \(step)")
        }
    }

    func disconnect() async {
        ledger.disconnectDidBegin()
        guard let session else { return }
        self.session = nil
        session.events.gate.userDidRequestDisconnect()
        let client = session.client
        if let pending = join {
            join = nil
            pending.abandon()
            // Let the join reach the agent its offer started, so it can be told.
            await pending.settle(within: Self.joinSettleBound)
            if !pending.hasSettled {
                Log.warning(.transport, "SmallWebRTC disconnect: the join in flight did not finish within \(Self.joinSettleBound); closing it")
            }
        }
        // Deliberate hangup: explicit end signal so the engine ends at once.
        if Self.sendClientMessage("end-call", on: client) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        do { try await client.disconnect() }
        catch { Log.error(.transport, "SmallWebRTC disconnect error: \(error)") }
        // The SDK's audio manager starts managing the shared AVAudioSession on connect
        // and only stops on release(), not on disconnect(). Left running, it re-applies
        // its own route (speaker) on every later route change, in calls on any transport.
        client.release()
        client.delegate = nil
    }

    /// How long `disconnect()` lets a join in flight finish before it closes it.
    private static let joinSettleBound: Duration = .seconds(2)

    /// Delivers a call-control signal to the agent: `.sent` once it was handed to the
    /// session's open data channel while its attempt still has an agent, `.failed`
    /// otherwise. The SDK reports nothing past that hand-off (see `sendClientMessage`).
    @discardableResult
    func send(_ signal: CallSignal) async -> CallSignalDelivery {
        guard let session else {
            Log.info(.transport, "SmallWebRTC client message \(signal.rawValue) dropped: no session")
            return .failed
        }
        let phase = phase(of: session)
        guard session.events.gate.carriesSignals(in: phase) else {
            Log.info(.transport, "SmallWebRTC client message \(signal.rawValue) dropped: no agent to hear it (\(phase), \(session.client.state))")
            return .failed
        }
        return Self.sendClientMessage(signal.rawValue, on: session.client) ? .sent : .failed
    }

    /// Sends an RTVI client message (`{"id", "label": "rtvi-ai", "type": "client-message",
    /// "data": {"t": type, "d": null}}`) on the data channel and returns whether it was
    /// handed to the SDK. Goes through the Pipecat transport rather than
    /// `PipecatClient.sendClientMessage`, which refuses until the bot is ready: the
    /// data channel is open from `.connected`, and a Pipecat bot's RTVI processor
    /// handles client messages without waiting for client-ready. The SDK's send
    /// swallows its errors and discards the data channel's own result, so a message
    /// lost in the channel (one closing before the SDK notices) still counts as handed over.
    @discardableResult
    private static func sendClientMessage(_ type: String, on client: PipecatClient) -> Bool {
        let state = client.state
        guard state == .connected || state == .ready else {
            Log.info(.transport, "SmallWebRTC client message \(type) dropped: the data channel is not open (\(state))")
            return false
        }
        do {
            try client.transport.sendMessage(message: .clientMessage(msgType: type))
            Log.info(.transport, "SmallWebRTC client message \(type) sent")
            return true
        } catch {
            Log.warning(.transport, "SmallWebRTC client message \(type) failed: \(error)")
            return false
        }
    }

    /// Leaves a session that is being replaced, without the end-call signal (the call
    /// goes on in the session that replaces it) and without reporting anything from
    /// it, and stops its audio manager before the next one starts.
    private static func retire(_ session: Session) async {
        session.events.gate.retire()
        session.client.delegate = nil
        do { try await session.client.disconnect() }
        catch { Log.error(.transport, "SmallWebRTC disconnect (replaced session) error: \(error)") }
        session.client.release()
    }

    /// A join in flight on the session counts as negotiating whatever the client's
    /// state says, so a second connect never joins on that client.
    private func phase(of session: Session) -> SmallWebRTCSessionPhase {
        join == nil ? Self.phase(of: session.client.state) : .negotiating
    }

    private static func phase(of state: TransportState) -> SmallWebRTCSessionPhase {
        switch state {
        case .initializing, .initialized, .authenticating, .authenticated, .connecting: .negotiating
        case .connected: .awaitingBot
        case .ready: .ready
        case .disconnecting: .leaving
        case .disconnected, .error: .idle
        @unknown default: .leaving
        }
    }

    func setMicEnabled(_ enabled: Bool) async {
        guard let client = session?.client else { return }
        do { try await client.enableMic(enable: enabled) }
        catch { Log.error(.transport, "SmallWebRTC enableMic(\(enabled)) error: \(error)") }
    }

    // The SDK models audio routes (speaker / earpiece / Bluetooth / wired) as its
    // "mic" devices, same surface as Daily.
    func availableAudioDevices() async -> [AudioDeviceInfo] {
        session?.client.getAllMics().map { AudioDeviceInfo(id: $0.id.id, name: $0.name) } ?? []
    }

    func selectedAudioDevice() async -> AudioDeviceInfo? {
        session?.client.selectedMic.map { AudioDeviceInfo(id: $0.id.id, name: $0.name) }
    }

    /// Asks the SDK to prefer the device, at once (or, with no client yet, before
    /// the next join) and for every later client of this transport, over the route
    /// the call started on.
    func setAudioDevice(_ id: String) async {
        guard let route = SmallWebRTCAudioRoute(deviceID: id) else {
            Log.warning(.audio, "SmallWebRTC setAudioDevice(\(id)) ignored: not a SmallWebRTC audio device")
            return
        }
        routes.engineDidRequest(route)
        Self.traceRoute("engine request: audio device \(route)")
        await applyRoute().value
    }

    /// The SDK owns its AVAudioSession configuration and its playout never stopped,
    /// so attaching starts nothing but the route: the agent is already audible, so
    /// the `call-connected` or `call-resumed` the engine sends next reaches an agent
    /// the user can hear. The engine's `setMicEnabled` that follows reopens capture.
    /// The first attach reads the route CallKit activated the call on, for the SDK
    /// to keep. If a device pass shows CallKit contention, the upgrade is
    /// RTCAudioSession manual-audio gating with the unordered-edges pattern
    /// (potential_skills/callkit.md).
    func attachAudioSession() async {
        Log.info(.audio, "SmallWebRTC attach (capture follows the engine's mic)")
        if !routes.hasAttached {
            let port = Self.readOutputPort()
            let devices = Set((session?.client.getAllMics() ?? []).compactMap { SmallWebRTCAudioRoute(deviceID: $0.id.id) })
            routes.attach(activeRoute: port.flatMap(SmallWebRTCAudioRoute.init(outputPort:)), devices: devices)
            Self.traceRoute("route at activation: \(port?.rawValue ?? "no output") -> keep \(Self.describe(routes.followed)); preferred audio device \(Self.describe(routes.wanted)) (\(routes.wantedReason))")
        }
        await applyRoute().value
    }

    /// Gives the SDK the gate's wanted route until the current client has it, one
    /// change at a time and always toward the latest wanted route. A call while an
    /// application runs returns that one, which picks up the latest route.
    @discardableResult
    private func applyRoute() -> Task<Void, Never> {
        if let routeApplication { return routeApplication }
        let task = Task { [weak self] in
            await self?.applyRouteChanges()
            self?.routeApplication = nil
        }
        routeApplication = task
        return task
    }

    private func applyRouteChanges() async {
        while let client = session?.client, let application = routes.beginApplying() {
            // An id the SDK does not know clears its preferred device
            // (`AudioDeviceType(deviceID:)` is nil for it).
            let id = application.route?.deviceID ?? ""
            Self.traceRoute("preferred audio device -> \(Self.describe(application.route)) (\(routes.wantedReason))")
            do {
                try await client.updateMic(micId: MediaDeviceId(id: id))
            } catch {
                routes.applyDidFail(application)
                Log.warning(.audio, "SmallWebRTC preferred audio device -> \(Self.describe(application.route)) refused: \(error)")
                Self.traceRoute("preferred audio device -> \(Self.describe(application.route)) refused: \(error)")
                return
            }
            Self.traceRoute("preferred audio device is \(Self.describe(application.route)): SDK selected \(client.selectedMic?.id.id ?? "none"), route \(Self.readOutputPort()?.rawValue ?? "no output")")
        }
    }

    /// The SDK reported its device list: a Bluetooth or wired device that came or
    /// went may move the route the transport keeps the call on.
    private func audioDevicesDidChange(_ ids: [String]) {
        let before = routes.wanted
        routes.devicesDidChange(Set(ids.compactMap(SmallWebRTCAudioRoute.init(deviceID:))))
        guard routes.wanted != before else { return }
        Self.traceRoute("devices now \(ids): preferred audio device \(Self.describe(before)) -> \(Self.describe(routes.wanted)) (\(routes.wantedReason))")
        applyRoute()
    }

    private static func readOutputPort() -> AVAudioSession.Port? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
    }

    private static func describe(_ route: SmallWebRTCAudioRoute?) -> String {
        route.map { "\($0)" } ?? "none (SDK default)"
    }

    /// Each route decision, to the call trace (which also writes it to Console).
    private static func traceRoute(_ line: String) {
        #if DEBUG
        CallTrace.record("smallwebrtc route: \(line)")
        #endif
    }

    /// Stops capture (the engine reopens it with `setMicEnabled` after the next
    /// attach). Playout cannot be stopped through the SDK (see the header).
    func detachAudioSession() async {
        Log.info(.audio, "SmallWebRTC detach: capture off; the agent's playout keeps running")
        guard let client = session?.client else { return }
        do { try await client.enableMic(enable: false) }
        catch { Log.error(.transport, "SmallWebRTC enableMic(false) on detach error: \(error)") }
    }
}

/// The SDK's `connect` for one join, run in a task of the transport's own so the
/// transport can stop waiting for it: the SDK's connect never returns once its peer
/// connection was closed before the data channel opened.
@MainActor
private final class SmallWebRTCJoin {
    enum Outcome {
        case joined
        case failed(any Error)
        /// A newer connect, the host's disconnect or the caller's cancellation took
        /// the join from its connect.
        case abandoned
    }

    private var result: Result<Void, any Error>?
    private var isAbandoned = false
    private var connectWaiter: CheckedContinuation<Outcome, Never>?
    private var settleWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID = 0

    var hasSettled: Bool { result != nil }

    init(client: PipecatClient, params: SmallWebRTCTransportConnectionParams) {
        Task { @MainActor [weak self] in
            let result: Result<Void, any Error>
            do {
                try await client.connect(transportParams: params)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self?.complete(result)
        }
    }

    /// Waits for the SDK's connect, unless the join is abandoned first. Called once,
    /// by the connect that started the join.
    func outcomeForConnect() async -> Outcome {
        if let outcome = currentOutcome { return outcome }
        return await withCheckedContinuation { connectWaiter = $0 }
    }

    /// Waits for the SDK's connect to return, at most `bound`.
    func settle(within bound: Duration) async {
        guard result == nil else { return }
        nextWaiterID += 1
        let id = nextWaiterID
        await withCheckedContinuation { continuation in
            settleWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: bound)
                self?.settleWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    /// Releases the connect waiting on this join. The SDK's connect runs on, so a
    /// `disconnect()` can let it finish.
    func abandon() {
        isAbandoned = true
        resumeConnect()
    }

    private var currentOutcome: Outcome? {
        if isAbandoned { return .abandoned }
        switch result {
        case .success: return .joined
        case .failure(let error): return .failed(error)
        case nil: return nil
        }
    }

    private func complete(_ result: Result<Void, any Error>) {
        self.result = result
        resumeConnect()
        let waiters = settleWaiters
        settleWaiters = [:]
        waiters.values.forEach { $0.resume() }
    }

    private func resumeConnect() {
        guard let outcome = currentOutcome, let waiter = connectWaiter else { return }
        connectWaiter = nil
        waiter.resume(returning: outcome)
    }
}

/// Translates the Pipecat client's delegate callbacks into `TransportEvent`s,
/// through the attempt's gate.
@MainActor
private final class SmallWebRTCEventMapper: PipecatClientDelegate {
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation
    var gate = SmallWebRTCConnectionGate()

    init(continuation: AsyncStream<TransportEvent>.Continuation) {
        self.continuation = continuation
    }

    nonisolated func onTransportStateChanged(state: TransportState) {
        Task { @MainActor in self.mapState(state) }
    }

    private func mapState(_ state: TransportState) {
        switch state {
        case .initializing, .initialized, .authenticating, .authenticated, .connecting, .connected:
            if gate.isLive { continuation.yield(.connecting) }
        case .ready:
            reportReady()
        case .disconnecting:
            break
        case .disconnected:
            if let event = gate.transportDidDisconnect() { continuation.yield(event) }
        case .error:
            // A connect that fails also throws, and the throw reports it.
            if gate.isLive { continuation.yield(.error(.connectionFailed("transport error"))) }
        @unknown default:
            break
        }
    }

    private func reportReady() {
        if let event = gate.transportDidBecomeReady() { continuation.yield(event) }
    }

    nonisolated func onBotReady(botReadyData: BotReadyData) {
        Task { @MainActor in self.reportReady() }
    }

    nonisolated func onBotDisconnected(participant: Participant) {
        Task { @MainActor in
            if let event = self.gate.botDidLeave() { self.continuation.yield(event) }
        }
    }

    nonisolated func onDisconnected() {
        // Authoritative disconnect is driven by onTransportStateChanged(.disconnected);
        // this is left to the state mapping to avoid double-emitting.
    }

    nonisolated func onBotStartedSpeaking() { continuation.yield(.botStartedSpeaking) }
    nonisolated func onBotStoppedSpeaking() { continuation.yield(.botStoppedSpeaking) }
    nonisolated func onUserStartedSpeaking() { continuation.yield(.userStartedSpeaking) }
    nonisolated func onUserStoppedSpeaking() { continuation.yield(.userStoppedSpeaking) }

    nonisolated func onRemoteAudioLevel(level: Float, participant: Participant) {
        continuation.yield(.remoteAudioLevel(level))
    }

    /// The SDK's device ids each time it reports its list, on the main actor.
    var onAvailableMics: ((_ ids: [String]) -> Void)?

    nonisolated func onAvailableMicsUpdated(mics: [MediaDeviceInfo]) {
        let ids = mics.map(\.id.id)
        Task { @MainActor in self.onAvailableMics?(ids) }
        continuation.yield(.audioDevicesChanged)
    }

    nonisolated func onMicUpdated(mic: MediaDeviceInfo?) {
        continuation.yield(.audioDevicesChanged)
    }

    nonisolated func onSpeakerUpdated(speaker: MediaDeviceInfo?) {
        continuation.yield(.audioDevicesChanged)
    }

    nonisolated func onError(message: RTVIMessageInbound) {
        let error = TransportError.underlying(String(describing: message))
        Task { @MainActor in
            if self.gate.isLive { self.continuation.yield(.error(error)) }
        }
    }
}
