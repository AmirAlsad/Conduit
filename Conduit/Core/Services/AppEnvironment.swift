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
    let callProvider: CallProviding
    let agentRepository: AgentRepository
    let announcer: SpokenStateAnnouncing
    let transportFactory: (TransportKind) -> Transport
    let callSession: CallSessionCoordinator

    init(
        modelContainer: ModelContainer,
        keychain: KeychainStoring,
        callProvider: CallProviding,
        agentRepository: AgentRepository,
        announcer: SpokenStateAnnouncing,
        transportFactory: @escaping (TransportKind) -> Transport,
        isPushToTalkEnabled: @escaping () -> Bool = { false }
    ) {
        self.modelContainer = modelContainer
        self.keychain = keychain
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

    /// The real app environment: a persistent SwiftData store and the real
    /// Keychain / Contacts / persistence / spoken-state services. CallKit and
    /// Daily's WebRTC audio can't run in the simulator, so calls there fall back
    /// to fakes — everything else (add-agent, Keychain, the contact mirror,
    /// persistence) is real on both. A real call is device-only.
    static func live() -> AppEnvironment {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Agent.self, CallLogEntry.self)
        } catch {
            Log.error(.app, "Persistent store unavailable, falling back to in-memory: \(error)")
            container = try! ModelContainer(
                for: Agent.self, CallLogEntry.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }

        let callProvider: CallProviding
        let transportFactory: (TransportKind) -> Transport
        #if targetEnvironment(simulator)
        callProvider = FakeCallProvider()
        transportFactory = { _ in FakeTransport() }
        #else
        callProvider = SystemCallProvider()
        transportFactory = { kind in
            switch kind {
            case .daily: PipecatDailyTransport()
            case .livekit: UnavailableTransport(kind: .livekit) // M6
            }
        }
        #endif

        return AppEnvironment(
            modelContainer: container,
            keychain: KeychainService(),
            callProvider: callProvider,
            agentRepository: SwiftDataAgentRepository(context: container.mainContext),
            announcer: SpeechSpokenStateAnnouncer(),
            transportFactory: transportFactory,
            isPushToTalkEnabled: { UserDefaults.standard.bool(forKey: SettingsStore.pushToTalkKey) }
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
            callProvider: FakeCallProvider(),
            agentRepository: SwiftDataAgentRepository(context: container.mainContext),
            announcer: FakeSpokenStateAnnouncer(),
            transportFactory: { _ in FakeTransport() },
            isPushToTalkEnabled: { UserDefaults.standard.bool(forKey: SettingsStore.pushToTalkKey) }
        )
    }
}
