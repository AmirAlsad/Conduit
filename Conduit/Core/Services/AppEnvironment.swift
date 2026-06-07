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
    let announcer: SpokenStateAnnouncing
    let transportFactory: (TransportKind) -> Transport
    let callSession: CallSessionCoordinator

    init(
        modelContainer: ModelContainer,
        keychain: KeychainStoring,
        contacts: ContactsMirroring,
        callProvider: CallProviding,
        agentRepository: AgentRepository,
        announcer: SpokenStateAnnouncing,
        transportFactory: @escaping (TransportKind) -> Transport,
        isPushToTalkEnabled: @escaping () -> Bool = { false }
    ) {
        self.modelContainer = modelContainer
        self.keychain = keychain
        self.contacts = contacts
        self.callProvider = callProvider
        self.agentRepository = agentRepository
        self.announcer = announcer
        self.transportFactory = transportFactory
        self.callSession = CallSessionCoordinator(
            callProvider: callProvider,
            transportFactory: transportFactory,
            keychain: keychain,
            repository: agentRepository,
            announcer: announcer,
            now: { .now },
            sleep: { try await Task.sleep(for: $0) },
            isPushToTalkEnabled: isPushToTalkEnabled
        )
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
            announcer: FakeSpokenStateAnnouncer(),
            transportFactory: { _ in FakeTransport() }
        )
    }
}
