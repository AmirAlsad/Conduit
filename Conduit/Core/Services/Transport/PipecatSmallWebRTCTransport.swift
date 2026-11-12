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
//  Hold: the SDK exposes no control over the agent's playout (its peer
//  connection and remote track are internal), so `detachAudioSession` can stop
//  capture but not playout. A held call stays silent only because the agent
//  honours `call-held`, which `send(_:)` delivers.
//
//  Call-control signals and the end-call signal travel as RTVI client messages
//  over the data channel, in the envelope the package's Daily adapter uses.
//
//  Attempts: `SmallWebRTCConnectionGate` decides what each connect attempt reports
//  and what a connect does with a session that is still up. `disconnect()` takes
//  the session away and releases its client, so a later connect builds a new one.
//
//  Errors: every connect error is `.connectionFailed`. The SDK's HTTP error for a
//  rejected offer carries only a message, no status code, so a 401 cannot be told
//  apart without matching text, and a wrong guess now ends a reconnecting call as a
//  bad token. A rejected API key is caught exactly one step earlier, by pairing.
//

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
        return Session(client: client, events: events)
    }

    // MARK: - CallTransport

    nonisolated var canConnectWhileRinging: Bool { false }

    func connect(_ connection: CallConnection) async throws {
        var session = self.session ?? makeSession()
        self.session = session
        switch session.events.gate.plan(for: Self.phase(of: session.client.state)) {
        case .join:
            break
        case .reportConnected:
            if let event = session.events.gate.reconfirmConnected() { continuation.yield(event) }
            return
        case .awaitJoinUnderWay:
            return
        case .replaceSession:
            await retire(session)
            session = makeSession()
            self.session = session
        }

        session.events.gate.connectDidStart()
        do {
            // A pairing agent's connection is the offer URL plus a short-lived
            // bearer for it — the engine key itself never rides the offer leg.
            // Each engine retry re-pairs and lands here with a fresh offer,
            // which spawns a fresh bot server-side (context resets).
            // The SDK copies these headers onto both the offer POST and the
            // trickle-ICE PATCH.
            let headers: [[String: String]] = connection.token.map { [["Authorization": "Bearer \($0)"]] } ?? []
            let params = SmallWebRTCTransportConnectionParams(
                webrtcRequestParams: APIRequest(endpoint: connection.url, headers: headers)
            )
            try await session.client.connect(transportParams: params)
        } catch {
            session.events.gate.connectDidFail()
            Log.error(.transport, "SmallWebRTC connect failed: \(error)")
            throw TransportError.connectionFailed(String(describing: error))
        }
    }

    func disconnect() async {
        guard let session else { return }
        self.session = nil
        session.events.gate.userDidRequestDisconnect()
        let client = session.client
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

    /// Delivers a call-control signal to the agent, best effort.
    func send(_ signal: CallSignal) async {
        guard let client = session?.client else {
            Log.info(.transport, "SmallWebRTC client message \(signal.rawValue) dropped: no session")
            return
        }
        Self.sendClientMessage(signal.rawValue, on: client)
    }

    /// Sends an RTVI client message (`{"id", "label": "rtvi-ai", "type": "client-message",
    /// "data": {"t": type, "d": null}}`) on the data channel and returns whether it was
    /// handed to the SDK. Goes through the Pipecat transport rather than
    /// `PipecatClient.sendClientMessage`, which refuses until the bot is ready: the
    /// data channel is open from `.connected`, and a Pipecat bot's RTVI processor
    /// handles client messages without waiting for client-ready.
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

    /// Leave a session that is being replaced without reporting anything from it,
    /// and stop its audio manager before the next one starts.
    private func retire(_ session: Session) async {
        session.events.gate.retire()
        session.client.delegate = nil
        do { try await session.client.disconnect() }
        catch { Log.error(.transport, "SmallWebRTC disconnect (replaced session) error: \(error)") }
        session.client.release()
    }

    private static func phase(of state: TransportState) -> SmallWebRTCSessionPhase {
        switch state {
        case .authenticating, .authenticated, .connecting, .connected: .joining
        case .ready: .ready
        case .disconnecting: .leaving
        case .initializing, .initialized, .disconnected, .error: .idle
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

    func setAudioDevice(_ id: String) async {
        guard let client = session?.client else { return }
        do { try await client.updateMic(micId: MediaDeviceId(id: id)) }
        catch { Log.error(.audio, "SmallWebRTC setAudioDevice(\(id)) error: \(error)") }
    }

    /// The SDK owns its AVAudioSession configuration and its playout never stopped,
    /// so attaching starts nothing; the engine's `setMicEnabled` that follows reopens
    /// capture. If a device pass shows CallKit contention, the upgrade is
    /// RTCAudioSession manual-audio gating with the unordered-edges pattern
    /// (potential_skills/callkit.md).
    func attachAudioSession() async {
        Log.info(.audio, "SmallWebRTC attach (capture follows the engine's mic)")
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
            continuation.yield(.connecting)
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

    nonisolated func onAvailableMicsUpdated(mics: [MediaDeviceInfo]) {
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
