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

import Foundation
import PipecatClientIOS
import PipecatClientIOSSmallWebrtc

@MainActor
final class PipecatSmallWebRTCTransport: CallTransport, PipecatClientDelegate {
    nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    private let client: PipecatClient
    private var didReportConnected = false
    private var userRequestedDisconnect = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
        // Join with the mic disabled; capture is enabled only on CallKit activation
        // (via setMicEnabled), preserving the audio-session-ownership invariant.
        self.client = PipecatClient(
            options: PipecatClientOptions(
                transport: PipecatClientIOSSmallWebrtc.SmallWebRTCTransport(),
                enableMic: false,
                enableCam: false
            )
        )
        self.client.delegate = self
    }

    // MARK: - CallTransport

    func connect(_ connection: CallConnection) async throws {
        didReportConnected = false
        userRequestedDisconnect = false
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
            try await client.connect(transportParams: params)
        } catch {
            Log.error(.transport, "SmallWebRTC connect failed: \(error)")
            throw TransportError.connectionFailed(String(describing: error))
        }
    }

    func disconnect() async {
        userRequestedDisconnect = true
        // Deliberate hangup: explicit end signal so the engine ends at once.
        // SmallWebRTC's data channel delivers client RTVI messages cleanly, so
        // the plain client-message path works (unlike LiveKit's raw envelope).
        if (try? client.sendClientMessage(msgType: "end-call")) != nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        do { try await client.disconnect() }
        catch { Log.error(.transport, "SmallWebRTC disconnect error: \(error)") }
    }

    func setMicEnabled(_ enabled: Bool) async {
        do { try await client.enableMic(enable: enabled) }
        catch { Log.error(.transport, "SmallWebRTC enableMic(\(enabled)) error: \(error)") }
    }

    // The SDK models audio routes (speaker / earpiece / Bluetooth / wired) as its
    // "mic" devices, same surface as Daily.
    func availableAudioDevices() async -> [AudioDeviceInfo] {
        client.getAllMics().map { AudioDeviceInfo(id: $0.id.id, name: $0.name) }
    }

    func selectedAudioDevice() async -> AudioDeviceInfo? {
        client.selectedMic.map { AudioDeviceInfo(id: $0.id.id, name: $0.name) }
    }

    func setAudioDevice(_ id: String) async {
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

    // MARK: - PipecatClientDelegate (→ TransportEvent)

    nonisolated func onTransportStateChanged(state: TransportState) {
        Task { @MainActor in self.mapState(state) }
    }

    private func mapState(_ state: TransportState) {
        switch state {
        case .initializing, .initialized, .authenticating, .authenticated, .connecting, .connected:
            continuation.yield(.connecting)
        case .ready:
            emitConnectedOnce()
        case .disconnecting:
            break
        case .disconnected:
            continuation.yield(.disconnected(reason: userRequestedDisconnect ? .requestedByUser : .networkDropped))
        case .error:
            continuation.yield(.error(.connectionFailed("transport error")))
        @unknown default:
            break
        }
    }

    private func emitConnectedOnce() {
        guard !didReportConnected else { return }
        didReportConnected = true
        continuation.yield(.connected)
    }

    nonisolated func onBotReady(botReadyData: BotReadyData) {
        Task { @MainActor in self.emitConnectedOnce() }
    }

    nonisolated func onBotDisconnected(participant: Participant) {
        continuation.yield(.disconnected(reason: .botLeft))
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
        continuation.yield(.error(.underlying(String(describing: message))))
    }
}
