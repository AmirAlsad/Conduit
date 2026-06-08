//
//  DebugDailyAutoConnect.swift
//  Conduit
//
//  DEBUG-only, headless connect-and-downlink check driven by launch environment
//  variables, so the path can be verified without UI taps:
//
//    CONDUIT_DEBUG_ENGINE_URL — the engine base URL (required to trigger)
//    CONDUIT_DEBUG_ENGINE_KEY — the bearer API key (required)
//    CONDUIT_DEBUG_AGENT_ID   — "live" (greets on connect; default) or "loopback"
//
//  It POSTs the engine's /connect, connects a real PipecatDailyTransport to the
//  returned Daily room, records every TransportEvent (the agent's greet shows up
//  as bot-speaking / remote-audio-level events), then disconnects. Results are
//  appended to `conduit-autoconnect.log` in the app's Documents directory AND
//  emitted via `Log`, so they can be read straight off disk regardless of os_log
//  capture timing. Credentials come from the environment — never stored/committed.
//

#if DEBUG
import Foundation

@MainActor
enum DebugDailyAutoConnect {
    static func runIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let baseString = env["CONDUIT_DEBUG_ENGINE_URL"],
              let baseURL = URL(string: baseString),
              let apiKey = env["CONDUIT_DEBUG_ENGINE_KEY"],
              !apiKey.isEmpty else { return }
        let agentID = env["CONDUIT_DEBUG_AGENT_ID"] ?? "live"

        truncateLog()
        record("START POST \(baseURL.absoluteString)/connect agent=\(agentID)")

        let creds: DebugEngineConnect.DailyCreds
        do {
            creds = try await DebugEngineConnect.fetchDaily(baseURL: baseURL, apiKey: apiKey, agentID: agentID)
        } catch {
            record("CONNECT-FAILED /connect: \(error)")
            return
        }
        record("PAIRED room=\(creds.roomURL.host() ?? "?") token=\(Log.redact(creds.token))")

        #if targetEnvironment(simulator)
        // Daily's WebRTC stack initializes the voice-processing I/O audio unit on
        // join; that unit aborts (SIGABRT) in the iOS Simulator, which has no audio
        // HAL for it. So the actual connect + downlink audio is device-only — the
        // sim verifies only the pairing/contract above. Don't crash the sim run.
        record("SKIP transport.connect — Daily audio is device-only (VPIO aborts in sim). Pairing OK.")
        record("FINISHED")
        return
        #else
        let transport = PipecatDailyTransport()
        let events = transport.events
        let logTask = Task {
            for await event in events { record("EVENT \(String(describing: event))") }
        }

        do {
            try await transport.connect(TransportConfig(kind: .daily, url: creds.roomURL, token: creds.token))
            record("connect() returned")
        } catch {
            record("CONNECT-FAILED transport: \(error)")
        }

        try? await Task.sleep(for: .seconds(20))
        await transport.disconnect()
        record("FINISHED")
        logTask.cancel()
        #endif
    }

    // MARK: - File-backed record (Documents/conduit-autoconnect.log)

    private static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("conduit-autoconnect.log")
    }

    private static func truncateLog() {
        guard let url = logURL else { return }
        try? Data().write(to: url)
    }

    private static func record(_ line: String) {
        Log.info(.transport, "DEBUG-AUTOCONNECT \(line)")
        guard let url = logURL, let data = "\(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
