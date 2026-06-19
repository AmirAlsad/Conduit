//
//  DebugSeed.swift
//  Conduit
//
//  DEBUG-only sample data so the list screens (Recents, Contacts, Agent Detail)
//  and the in-call surface render a believable experience for App Store captures.
//  Triggered by CONDUIT_DEBUG_SEED=1; seeds a roster + call history only when the
//  store is empty, so it never duplicates across launches.
//

#if DEBUG
import Foundation

@MainActor
enum DebugSeed {
    static func runIfRequested(_ environment: AppEnvironment) {
        guard ProcessInfo.processInfo.environment["CONDUIT_DEBUG_SEED"] == "1" else { return }
        seedIfEmpty(environment)
    }

    /// Seed the roster + call log when the store is empty, and return the agent to
    /// feature on the in-call screen. Idempotent — safe to call on every launch and
    /// from the in-call debug path (which needs an agent regardless of the seed flag).
    @discardableResult
    static func seedIfEmpty(_ environment: AppEnvironment) -> Agent? {
        let repository = environment.agentRepository
        let existing = (try? repository.fetchAll()) ?? []
        guard existing.isEmpty else { return hero(in: existing) }

        let agents = roster.map { spec -> Agent in
            let agent = Agent(
                name: spec.name,
                detail: spec.detail,
                colorToken: spec.color,
                transportKind: spec.transport,
                connectionURL: URL(string: spec.connection)
            )
            repository.insert(agent)
            return agent
        }
        let byName = Dictionary(uniqueKeysWithValues: agents.map { ($0.name, $0) })

        for call in callLog {
            guard let agent = byName[call.agent] else { continue }
            repository.addCallLogEntry(
                CallLogEntry(
                    agent: agent,
                    direction: call.direction,
                    startedAt: .now.addingTimeInterval(call.secondsAgo),
                    duration: call.duration,
                    outcome: call.outcome,
                    transportKind: agent.transportKind,
                    failureReason: call.failureReason
                )
            )
        }
        try? repository.save()
        return hero(in: agents)
    }

    /// The agent featured on the in-call screen (stable; falls back to the first).
    static func hero(in agents: [Agent]) -> Agent? {
        agents.first { $0.name == heroName } ?? agents.first
    }

    private static let heroName = "Atlas"

    // MARK: - Roster

    private struct AgentSpec {
        let name: String
        let detail: String
        let color: AgentColor
        let transport: TransportKind
        let connection: String
    }

    private static let roster: [AgentSpec] = [
        AgentSpec(name: "Atlas", detail: "Research Assistant",
                  color: .blue, transport: .daily, connection: "https://myteam.daily.co/atlas"),
        AgentSpec(name: "Cleo", detail: "Customer Support",
                  color: .pink, transport: .livekit, connection: "wss://acme.livekit.cloud"),
        AgentSpec(name: "Juniper", detail: "Schedule & Reminders",
                  color: .green, transport: .livekit, connection: "wss://juniper.livekit.cloud"),
        AgentSpec(name: "Nova", detail: "Morning News Brief",
                  color: .orange, transport: .daily, connection: "https://myteam.daily.co/nova"),
        AgentSpec(name: "Orion", detail: "Home Assistant",
                  color: .teal, transport: .smallwebrtc, connection: "https://orion.local"),
        AgentSpec(name: "Sage", detail: "Coding Copilot",
                  color: .indigo, transport: .smallwebrtc, connection: "https://sage.lan"),
    ]

    // MARK: - Call history

    private struct CallSpec {
        let agent: String
        let direction: CallDirection
        let outcome: CallOutcome
        let duration: TimeInterval
        let secondsAgo: TimeInterval
        var failureReason: CallFailureReason?
    }

    private static let callLog: [CallSpec] = [
        CallSpec(agent: "Atlas", direction: .outgoing, outcome: .completed, duration: 252, secondsAgo: -2_700),
        CallSpec(agent: "Juniper", direction: .incoming, outcome: .completed, duration: 98, secondsAgo: -7_200),
        CallSpec(agent: "Sage", direction: .outgoing, outcome: .completed, duration: 767, secondsAgo: -28_800),
        CallSpec(agent: "Nova", direction: .incoming, outcome: .completed, duration: 125, secondsAgo: -90_000),
        CallSpec(agent: "Cleo", direction: .outgoing, outcome: .failed, duration: 0, secondsAgo: -97_000,
                 failureReason: .badToken),
        CallSpec(agent: "Orion", direction: .incoming, outcome: .noAnswer, duration: 0, secondsAgo: -180_000),
        CallSpec(agent: "Atlas", direction: .outgoing, outcome: .completed, duration: 42, secondsAgo: -260_000),
        CallSpec(agent: "Sage", direction: .incoming, outcome: .completed, duration: 339, secondsAgo: -350_000),
    ]
}
#endif
