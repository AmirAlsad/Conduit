//
//  DebugSeed.swift
//  Conduit
//
//  DEBUG-only sample data so list screens (Recents, Contacts) can be screenshotted
//  in the simulator. Triggered by CONDUIT_DEBUG_SEED=1; inserts one agent + a
//  completed call only when the store is empty, so it never duplicates.
//

#if DEBUG
import Foundation

@MainActor
enum DebugSeed {
    static func runIfRequested(_ environment: AppEnvironment) {
        guard ProcessInfo.processInfo.environment["CONDUIT_DEBUG_SEED"] == "1" else { return }
        let repository = environment.agentRepository
        guard (try? repository.fetchAll())?.isEmpty ?? false else { return }

        let agent = Agent(
            name: "Testing",
            detail: "Echo bot",
            transportKind: .daily,
            connectionURL: URL(string: "https://example.daily.co/room")
        )
        repository.insert(agent)
        repository.addCallLogEntry(
            CallLogEntry(
                agent: agent,
                direction: .outgoing,
                startedAt: .now.addingTimeInterval(-1680),
                duration: 116,
                outcome: .completed,
                transportKind: .daily
            )
        )
        try? repository.save()
    }
}
#endif
