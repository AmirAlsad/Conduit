//
//  DebugDailyConnectModel.swift
//  Conduit
//
//  DEBUG-only driver for the CallKit-free "connect and downlink" path: it POSTs
//  the engine's /connect, creates a real PipecatDailyTransport, connects to the
//  returned Daily room, and surfaces the live TransportEvent stream. The simulator
//  plays inbound audio but can't publish the mic, so this validates connect +
//  downlink (the agent's greet), not a full conversation (that's the M3 device
//  spike). No CallKit involved. Credentials are entered at runtime, never stored.
//

#if DEBUG
import Foundation

@MainActor
@Observable
final class DebugDailyConnectModel {
    var baseURL = ""
    var apiKey = ""
    var agentID = "live"
    private(set) var stateText = "idle"
    private(set) var log: [String] = []
    private(set) var isBusy = false

    private var transport: PipecatDailyTransport?
    private var eventTask: Task<Void, Never>?

    func connect() {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base), !base.isEmpty else {
            append("✗ invalid base URL")
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            append("✗ enter the API key")
            return
        }

        isBusy = true
        stateText = "pairing"
        append("→ POST \(base)/connect agent=\(agentID)")
        Task {
            do {
                let creds = try await DebugEngineConnect.fetchDaily(baseURL: url, apiKey: key, agentID: agentID)
                append("✓ paired: room \(creds.roomURL.host() ?? "?")")
                #if targetEnvironment(simulator)
                // Daily's voice-processing audio unit aborts in the simulator; the
                // real connect + downlink audio is device-only.
                append("⚠︎ device-only: Daily audio (VPIO) aborts in the simulator — run on a device.")
                stateText = "paired (device-only)"
                #else
                let transport = PipecatDailyTransport()
                self.transport = transport
                subscribe(to: transport)
                stateText = "connecting"
                try await transport.connect(TransportConfig(kind: .daily, url: creds.roomURL, token: creds.token))
                append("✓ connect() returned")
                #endif
            } catch {
                append("✗ \(error)")
                stateText = "failed"
            }
            isBusy = false
        }
    }

    func disconnect() {
        append("→ disconnect()")
        let transport = self.transport
        Task { await transport?.disconnect() }
    }

    private func subscribe(to transport: PipecatDailyTransport) {
        eventTask?.cancel()
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .connecting: stateText = "connecting"
        case .connected: stateText = "connected ✓"
        case .reconnecting: stateText = "reconnecting"
        case .disconnected(let reason): stateText = "disconnected(\(reason))"
        case .error: stateText = "error"
        default: break
        }
        append(String(describing: event))
    }

    private func append(_ line: String) {
        log.insert(line, at: 0)
        if log.count > 200 { log.removeLast() }
    }
}
#endif
