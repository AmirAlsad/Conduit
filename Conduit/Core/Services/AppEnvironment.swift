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
    let contactSync: ContactSyncing
    let callProvider: CallProviding
    let agentRepository: AgentRepository
    let announcer: SpokenStateAnnouncing
    let interruptionObserver: AudioInterruptionObserving
    let transportFactory: (TransportKind) -> Transport
    let callSession: CallSessionCoordinator
    /// Set by the AppDelegate once PushKit is up (`VoIPPushService` is the real
    /// implementation), so saving an inbound-enabled agent registers immediately
    /// instead of waiting for the next launch. Weak: the delegate owns the service.
    weak var inboundRegistrar: InboundRegistering?
    /// A parsed conduit:// add-agent link awaiting consumption. Set by onOpenURL
    /// at the app root; consumed by ContactsView when it can present the sheet
    /// (deferred while another sheet or a call is up).
    var pendingAgentLink: AgentDeepLink?
    /// An agent id awaiting a Siri-initiated call. Set by CallAgentIntent /
    /// the SiriKit handler; consumed by RootTabView only once the scene is
    /// .active — dialing earlier makes CallKit reject the CXStartCallAction
    /// (the cold-launch-from-Siri race).
    var pendingSiriCall: UUID?

    init(
        modelContainer: ModelContainer,
        keychain: KeychainStoring,
        contactSync: ContactSyncing,
        callProvider: CallProviding,
        agentRepository: AgentRepository,
        announcer: SpokenStateAnnouncing,
        interruptionObserver: AudioInterruptionObserving,
        transportFactory: @escaping (TransportKind) -> Transport,
        isPushToTalkEnabled: @escaping () -> Bool = { false }
    ) {
        self.modelContainer = modelContainer
        self.keychain = keychain
        self.contactSync = contactSync
        self.callProvider = callProvider
        self.agentRepository = agentRepository
        self.announcer = announcer
        self.interruptionObserver = interruptionObserver
        self.transportFactory = transportFactory
        self.callSession = CallSessionCoordinator(
            callProvider: callProvider,
            transportFactory: transportFactory,
            keychain: keychain,
            repository: agentRepository,
            announcer: announcer,
            interruptionObserver: interruptionObserver,
            missedCallNotifier: MissedCallNotifier(),
            ringStatusReporter: RingStatusReporter(),
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
        // UI tests launch with `--uitest` to get a fresh in-memory store each run, so
        // seeded fixtures are deterministic and don't depend on leftover device state.
        #if DEBUG
        let ephemeral = ProcessInfo.processInfo.arguments.contains("--uitest")
        #else
        let ephemeral = false
        #endif
        do {
            container = ephemeral
                ? try ModelContainer(
                    for: Agent.self, CallLogEntry.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
                : try ModelContainer(for: Agent.self, CallLogEntry.self)
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
            case .livekit: LiveKitTransport()
            case .smallwebrtc: PipecatSmallWebRTCTransport()
            }
        }
        #endif

        return AppEnvironment(
            modelContainer: container,
            keychain: KeychainService(),
            contactSync: ContactSyncService(),
            callProvider: callProvider,
            agentRepository: SwiftDataAgentRepository(context: container.mainContext),
            announcer: SpeechSpokenStateAnnouncer(),
            interruptionObserver: SystemAudioInterruptionObserver(),
            transportFactory: transportFactory,
            isPushToTalkEnabled: { UserDefaults.standard.bool(forKey: SettingsStore.pushToTalkKey) }
        )
    }

    /// The process-wide live environment. The SwiftUI `App` and the UIKit
    /// `AppDelegate` (PushKit) reach the same instance, so an inbound VoIP push
    /// routes into the same coordinator the UI observes.
    static let shared = live()

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
            contactSync: FakeContactSync(),
            callProvider: FakeCallProvider(),
            agentRepository: SwiftDataAgentRepository(context: container.mainContext),
            announcer: FakeSpokenStateAnnouncer(),
            interruptionObserver: FakeAudioInterruptionObserver(),
            transportFactory: { _ in FakeTransport() },
            isPushToTalkEnabled: { UserDefaults.standard.bool(forKey: SettingsStore.pushToTalkKey) }
        )
    }
}
