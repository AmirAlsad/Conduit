//
//  AppEnvironment.swift
//  Conduit
//
//  The composition root. Owns the SwiftData container and the protocol-typed
//  services, injected into the view tree via `.environment(_:)`. ViewModels read
//  only the protocols they need, so each test wires exactly its fakes.
//
//  `inMemory()` wires fakes + an in-memory store (previews, tests, and the M0
//  shell). The live wiring is introduced as the real services land (Daily
//  transport WS-2, CallKit WS-3, Keychain/Contacts WS-4) — at which point a
//  `live()` factory selects them and a persistent store.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class AppEnvironment {
    let modelContainer: ModelContainer
    let keychain: KeychainStoring
    let contacts: ContactsMirroring
    let callProvider: CallProviding
    let agentRepository: AgentRepository
    let transportFactory: (TransportKind) -> Transport

    init(
        modelContainer: ModelContainer,
        keychain: KeychainStoring,
        contacts: ContactsMirroring,
        callProvider: CallProviding,
        agentRepository: AgentRepository,
        transportFactory: @escaping (TransportKind) -> Transport
    ) {
        self.modelContainer = modelContainer
        self.keychain = keychain
        self.contacts = contacts
        self.callProvider = callProvider
        self.agentRepository = agentRepository
        self.transportFactory = transportFactory
    }

    /// All-fakes environment over an in-memory SwiftData store.
    static func inMemory() -> AppEnvironment {
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: Agent.self, CallLogEntry.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        } catch {
            fatalError("Failed to build in-memory ModelContainer: \(error)")
        }
        return AppEnvironment(
            modelContainer: container,
            keychain: InMemoryKeychain(),
            contacts: FakeContactsMirror(),
            callProvider: FakeCallProvider(),
            agentRepository: SwiftDataAgentRepository(context: container.mainContext),
            transportFactory: { _ in FakeTransport() }
        )
    }
}
