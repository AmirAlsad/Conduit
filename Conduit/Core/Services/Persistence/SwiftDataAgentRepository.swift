//
//  SwiftDataAgentRepository.swift
//  Conduit
//
//  `AgentRepository` over a SwiftData `ModelContext`. The same implementation
//  serves the running app (persistent container) and tests/previews (in-memory
//  container) — "fake" persistence is just a different container configuration.
//

import Foundation
import SwiftData

@MainActor
final class SwiftDataAgentRepository: AgentRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func fetchAll() throws -> [Agent] {
        try context.fetch(
            FetchDescriptor<Agent>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
    }

    func fetch(id: UUID) throws -> Agent? {
        var descriptor = FetchDescriptor<Agent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func insert(_ agent: Agent) {
        context.insert(agent)
    }

    func delete(_ agent: Agent) {
        context.delete(agent)
    }

    func addCallLogEntry(_ entry: CallLogEntry) {
        context.insert(entry)
    }

    func deleteCallLogEntry(_ entry: CallLogEntry) {
        context.delete(entry)
    }

    func save() throws {
        try context.save()
    }
}
