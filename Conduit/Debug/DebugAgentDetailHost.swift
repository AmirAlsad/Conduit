//
//  DebugAgentDetailHost.swift
//  Conduit
//
//  DEBUG-only host that seeds the roster and renders the hero agent's detail screen
//  directly (CONDUIT_DEBUG_DETAIL=1), so it can be screenshotted in the simulator
//  without an accessibility tap — iOS 26's simulator reports a 0x0 frame, which
//  breaks tap-by-identifier navigation. Resolves the agent reactively via @Query so
//  it appears once the seed lands (no side effects during view construction).
//

#if DEBUG
import SwiftData
import SwiftUI

struct DebugAgentDetailHost: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: [SortDescriptor(\Agent.name)]) private var agents: [Agent]

    var body: some View {
        NavigationStack {
            if let hero = agents.first(where: { $0.name == "Atlas" }) ?? agents.first {
                AgentDetailView(agent: hero)
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .task { DebugSeed.seedIfEmpty(environment) }
    }
}
#endif
