//
//  AgentRepository.swift
//  Conduit
//
//  Thin seam over the SwiftData `ModelContext` for mutations and non-view fetches
//  (e.g. test-connection, redial). List screens use `@Query` directly; this exists
//  so flows that mutate or look up agents stay testable against an in-memory store.
//  Main-actor: all SwiftData mutation in this app happens on the main context.
//

import Foundation

@MainActor
protocol AgentRepository {
    func fetchAll() throws -> [Agent]
    func fetch(id: UUID) throws -> Agent?
    func insert(_ agent: Agent)
    func delete(_ agent: Agent)
    func addCallLogEntry(_ entry: CallLogEntry)
    func deleteCallLogEntry(_ entry: CallLogEntry)
    func save() throws
}
