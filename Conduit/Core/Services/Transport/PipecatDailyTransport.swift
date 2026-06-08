//
//  PipecatDailyTransport.swift
//  Conduit
//
//  The real Daily transport: wraps the Pipecat iOS client (`PipecatClient` + the
//  Daily `DailyTransport`) behind Conduit's `Transport` protocol. Translates the
//  RTVI/Daily delegate callbacks into Conduit's SDK-agnostic `TransportEvent`s —
//  no RTVI/Daily type leaks upward.
//
//  Named `PipecatDailyTransport` to avoid colliding with the SDK's own
//  `DailyTransport`; conformance is qualified to `Conduit.Transport` for the same
//  reason (`PipecatClientIOS` also declares a `Transport`).
//
//  Audio-session note: the Daily SDK manages `AVAudioSession` itself and has no
//  documented hook to defer activation to CallKit (this is the M3 spike). For now
//  we join with the mic DISABLED and only enable capture via `setMicEnabled` —
//  which the coordinator calls after CallKit activation — so the mic is never hot
//  before activation. `attachAudioSession`/`detachAudioSession` are no-ops here
//  because Daily owns the session; they exist to satisfy the seam.
//

import Foundation
import PipecatClientIOS
import PipecatClientIOSDaily

@MainActor
final class PipecatDailyTransport: Conduit.Transport, PipecatClientDelegate {
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
                transport: PipecatClientIOSDaily.DailyTransport(),
                enableMic: false,
                enableCam: false
            )
        )
        self.client.delegate = self
    }

    // MARK: - Conduit.Transport

    func connect(_ config: TransportConfig) async throws {
        didReportConnected = false
        userRequestedDisconnect = false
        do {
            if let endpoint = config.pairingEndpoint {
                // The user's server mints a fresh room + token per call and the bot
                // joins it; we POST the endpoint and connect with what it returns.
                let _: DailyTransportConnectionParams = try await client.startBotAndConnect(
                    startBotParams: APIRequest(endpoint: endpoint)
                )
            } else {
                let params = DailyTransportConnectionParams(
                    roomUrl: config.url.absoluteString,
                    token: config.token.isEmpty ? nil : config.token
                )
                try await client.connect(transportParams: params)
            }
        } catch {
            Log.error(.transport, "Daily connect failed: \(error)")
            throw TransportError.connectionFailed(String(describing: error))
        }
    }

    func disconnect() async {
        userRequestedDisconnect = true
        do { try await client.disconnect() }
        catch { Log.error(.transport, "Daily disconnect error: \(error)") }
    }

    func setMicEnabled(_ enabled: Bool) async {
        do { try await client.enableMic(enable: enabled) }
        catch { Log.error(.transport, "Daily enableMic(\(enabled)) error: \(error)") }
    }

    func attachAudioSession() async {
        // Daily owns the AVAudioSession; nothing to attach here. The CallKit-owned
        // activation handshake for Daily is the M3 on-device spike.
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

    nonisolated func onError(message: RTVIMessageInbound) {
        continuation.yield(.error(.underlying(String(describing: message))))
    }
}
