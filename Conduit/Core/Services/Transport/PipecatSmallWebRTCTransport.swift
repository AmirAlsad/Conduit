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
//  engine calls after CallKit activation. `attachAudioSession`/
//  `detachAudioSession` are no-ops pending the on-device audio verdict.
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
        // SmallWebRTC's data channel delivers client RTVI messages cleanly, so
        // the plain client-message path works (unlike LiveKit's raw envelope).
        if (try? client.sendClientMessage(msgType: "end-call")) != nil {
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

    func attachAudioSession() async {
        // The SDK owns its AVAudioSession configuration; nothing to attach. If
        // the device pass shows CallKit contention, the upgrade is RTCAudioSession
        // manual-audio gating with the unordered-edges pattern (potential_skills/callkit.md).
    }

    func detachAudioSession() async {
        // See attachAudioSession.
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
