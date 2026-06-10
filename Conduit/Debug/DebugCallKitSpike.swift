//
//  DebugCallKitSpike.swift
//  Conduit
//
//  DEBUG-only, env-driven device spike for the CallKit↔Daily audio-session seam —
//  the riskiest boundary in the app. It drives the REAL CallSessionCoordinator
//  wired with the REAL SystemCallProvider (CallKit) + PipecatDailyTransport +
//  SystemAudioSession, placing an actual CallKit call to the engine, to answer
//  empirically: does Daily's self-managed audio compose with CallKit owning
//  activation?
//
//  Trigger (device only — CallKit doesn't run in the sim):
//    CONDUIT_DEBUG_CALLKIT=1  + the CONDUIT_DEBUG_ENGINE_* vars (see auto-connect).
//
//  Records the call-state lifecycle to `conduit-callkit-spike.log` in Documents.
//  On the phone you should hear the `live` agent greet you through the CallKit call;
//  grant the microphone prompt to also talk back.
//

#if DEBUG
import Foundation
import SwiftData

@MainActor
enum DebugCallKitSpike {
    static func runIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard env["CONDUIT_DEBUG_CALLKIT"] == "1" else { return }
        guard let baseString = env["CONDUIT_DEBUG_ENGINE_URL"],
              let baseURL = URL(string: baseString),
              let apiKey = env["CONDUIT_DEBUG_ENGINE_KEY"],
              !apiKey.isEmpty else { return }
        let agentID = env["CONDUIT_DEBUG_AGENT_ID"] ?? "live"

        truncateLog()
        record("SPIKE START agent=\(agentID) (in-app pairing)")

        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: Agent.self, CallLogEntry.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        } catch {
            record("CONTAINER-FAILED \(error)")
            return
        }
        let repository = SwiftDataAgentRepository(context: container.mainContext)

        // Exercise the real in-app pairing path: the transport POSTs this endpoint
        // (via PairingClient) for a fresh room+token per call, rather than the spike
        // pre-fetching them. This is what the user-facing add-agent flow does.
        let pairingEndpoint = baseURL.appendingPathComponent("connect")
        let agent = Agent(
            name: "Conduit Spike",
            detail: agentID,
            transportKind: .daily,
            pairingEndpoint: pairingEndpoint
        )
        repository.insert(agent)
        try? repository.save()

        let keychain = InMemoryKeychain()
        try? keychain.setToken(apiKey, for: KeychainTokenRef(account: agent.keychainTokenRef))
        record("agent created (pairing endpoint host=\(pairingEndpoint.host() ?? "?"))")

        let coordinator = CallSessionCoordinator(
            callProvider: SystemCallProvider(),
            transportFactory: { _ in PipecatDailyTransport() },
            keychain: keychain,
            repository: repository,
            announcer: SpeechSpokenStateAnnouncer(),
            interruptionObserver: SystemAudioInterruptionObserver(),
            missedCallNotifier: MissedCallNotifier(),
            ringStatusReporter: RingStatusReporter(),
            now: { .now },
            sleep: { try await Task.sleep(for: $0) },
            isPushToTalkEnabled: { false }
        )

        record("placeCall")
        await coordinator.placeCall(agent)

        // Observe the call for ~45s: CallKit UI + didActivate + Daily connect +
        // the agent's greet. Records state and bot-speaking transitions.
        var lastState = ""
        var lastSpeaking = false
        var lastActivated = false
        for _ in 0..<90 {
            let state = String(describing: coordinator.state)
            if state != lastState { record("state=\(state)"); lastState = state }
            if coordinator.isAudioActivated != lastActivated {
                record("audioActivated=\(coordinator.isAudioActivated)")
                lastActivated = coordinator.isAudioActivated
            }
            if coordinator.isBotSpeaking != lastSpeaking {
                record("botSpeaking=\(coordinator.isBotSpeaking)")
                lastSpeaking = coordinator.isBotSpeaking
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        record("endCall")
        await coordinator.endCall()
        try? await Task.sleep(for: .seconds(2))
        record("state=\(String(describing: coordinator.state))")
        record("SPIKE FINISHED")
    }

    // MARK: - File-backed record (Documents/conduit-callkit-spike.log)

    private static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("conduit-callkit-spike.log")
    }

    private static func truncateLog() {
        guard let url = logURL else { return }
        try? Data().write(to: url)
    }

    private static func record(_ line: String) {
        Log.info(.callkit, "SPIKE \(line)")
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
