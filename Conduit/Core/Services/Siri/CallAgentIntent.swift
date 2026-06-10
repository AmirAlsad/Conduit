//
//  CallAgentIntent.swift
//  Conduit
//
//  "Hey Siri, call <agent> on Conduit." The intent must open the app:
//  CXStartCallAction from a background-invoked App Intent is rejected by CallKit
//  (CXErrorCodeRequestTransactionError .invalidAction), so openAppWhenRun is
//  load-bearing, and perform() never dials directly — it parks the agent id on
//  AppEnvironment.pendingSiriCall, which RootTabView consumes once the scene is
//  actually .active (the cold-launch-from-Siri race).
//
//  The type name and the `agent` parameter name are FROZEN — App Shortcut
//  identity keys on them (see AgentEntity.swift).
//

import AppIntents
import Foundation

struct CallAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Call Agent"
    static let description = IntentDescription("Starts a voice call to one of your agents.")
    static let openAppWhenRun = true

    @Parameter(title: "Agent")
    var agent: AgentEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let chosen: AgentEntity
        if let agent {
            chosen = agent
        } else {
            // Static-phrase path ("Call my agent on Conduit"): pick or ask.
            let agents = (try? AppEnvironment.shared.agentRepository.fetchAll()) ?? []
            switch agents.count {
            case 0:
                throw CallAgentError.noAgents
            case 1:
                chosen = AgentEntity(agent: agents[0])
            default:
                chosen = try await $agent.requestDisambiguation(
                    among: agents.map(AgentEntity.init),
                    dialog: "Which agent?"
                )
            }
        }
        Log.info(.call, "Siri dial requested: \(chosen.name)")
        AppEnvironment.shared.pendingSiriCall = chosen.id
        return .result()
    }
}

enum CallAgentError: Error, CustomLocalizedStringResourceConvertible {
    case noAgents

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noAgents:
            return "You haven't added any agents yet. Add one in Conduit first."
        }
    }
}
