//
//  AgentEntityQuery.swift
//  Conduit
//
//  Feeds Siri's vocabulary (suggestedEntities → the values usable inside the
//  "Call <agent> on Conduit" phrase) and resolves spoken strings via the tested
//  AgentNameMatcher. Thin by design: all decision logic lives in the matcher.
//

import AppIntents
import Foundation

struct AgentEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [AgentEntity] {
        let agents = (try? AppEnvironment.shared.agentRepository.fetchAll()) ?? []
        return agents.filter { identifiers.contains($0.id) }.map(AgentEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [AgentEntity] {
        let agents = (try? AppEnvironment.shared.agentRepository.fetchAll()) ?? []
        let candidates = agents.map { AgentNameMatcher.Candidate(id: $0.id, name: $0.name) }
        switch AgentNameMatcher.match(string, in: candidates) {
        case .none:
            return []
        case .unique(let match):
            return [AgentEntity(id: match.id, name: match.name)]
        case .ambiguous(let matches):
            // Return the full set; Siri/Shortcuts drives disambiguation.
            return matches.map { AgentEntity(id: $0.id, name: $0.name) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [AgentEntity] {
        let agents = (try? AppEnvironment.shared.agentRepository.fetchAll()) ?? []
        return agents.map(AgentEntity.init)
    }
}
