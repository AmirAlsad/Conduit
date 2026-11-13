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

import ConduitCallEngine
import ConduitCallEngineDaily
import ConduitCallEngineLiveKit
import ConduitCallEngineTesting
import Foundation
import SwiftData

@MainActor
@Observable
final class AppEnvironment {
    let modelContainer: ModelContainer
    let keychain: KeychainStoring
    let contactSync: ContactSyncing
    let agentRepository: AgentRepository
    let announcer: SpokenStateAnnouncing
    let microphone: MicrophonePermissionProviding
    let transportFactory: (TransportKind) -> CallTransport
    let callEngine: CallEngine
    /// The stand-in CallKit/PushKit system behind `callEngine` when it is simulated
    /// (the simulator, previews, tests); nil on a device, where the engine is real.
    let simulatedCallSystem: SimulatedCallSystem?
    /// The engine's delegate: call targets, history, spoken cues, Siri donation,
    /// VoIP token registration.
    let callHost: AgentCallHost
    /// Set by the AppDelegate once PushKit is up (`AgentCallHost` is the real
    /// implementation), so saving an inbound-enabled agent registers immediately
    /// instead of waiting for the next launch.
    weak var inboundRegistrar: InboundRegistering?
    /// A parsed conduit:// add-agent link awaiting consumption. Set by onOpenURL
    /// at the app root; consumed by ContactsView when it can present the sheet
    /// (deferred while another sheet or a call is up).
    var pendingAgentLink: AgentDeepLink?
    /// A Siri-initiated dial request. Set by CallAgentIntent / the SiriKit
    /// continuation; consumed by RootTabView only once the scene is .active —
    /// dialing earlier makes CallKit reject the CXStartCallAction (the
    /// cold-launch-from-Siri race). Expires after 30s so a never-consumed
    /// request (locked-phone attempt) can't resurface as a phantom call.
    var pendingSiriCall: PendingSiriCall?
    /// Whether the user minimized the in-call surface (the call stays fully alive;
    /// only the projection is dismissed). RootTabView gates the in-call cover on
    /// this and clears it to re-present on return. Never touches the engine.
    var isCallScreenMinimized: Bool = false
    /// The name of the agent a call was not placed to because the app may not use
    /// the microphone. RootTabView explains it, with a way to Settings, and clears it.
    var callRefusedForMicrophone: String?

    init(
        modelContainer: ModelContainer,
        keychain: KeychainStoring,
        contactSync: ContactSyncing,
        agentRepository: AgentRepository,
        announcer: SpokenStateAnnouncing,
        microphone: MicrophonePermissionProviding,
        transportFactory: @escaping (TransportKind) -> CallTransport,
        isPushToTalkEnabled: @escaping @MainActor () -> Bool = { false },
        simulatedCallSystem: SimulatedCallSystem? = nil,
        makeCallEngine: (CallEngineConfiguration) -> CallEngine
    ) {
        self.modelContainer = modelContainer
        self.keychain = keychain
        self.contactSync = contactSync
        self.agentRepository = agentRepository
        self.announcer = announcer
        self.microphone = microphone
        self.transportFactory = transportFactory
        self.simulatedCallSystem = simulatedCallSystem
        self.callHost = AgentCallHost(
            repository: agentRepository,
            keychain: keychain,
            announcer: announcer,
            missedCallNotifier: MissedCallNotifier(),
            transportFactory: transportFactory
        )
        self.callEngine = makeCallEngine(Self.callEngineConfiguration(isPushToTalkEnabled: isPushToTalkEnabled))
        callEngine.delegate = callHost
        callHost.engine = callEngine
    }

    /// The engine configuration the app ships. A placed call's ringback plays its
    /// start delay and first tone in full before the call shows connected and
    /// "Connected" is spoken; answered calls have no ringback and are never held
    /// connecting. Calls start where iOS puts them (no speaker default).
    static func callEngineConfiguration(
        isPushToTalkEnabled: @escaping @MainActor () -> Bool = { false }
    ) -> CallEngineConfiguration {
        CallEngineConfiguration(
            unknownCallerName: "Agent",
            minimumOutgoingConnectingDuration: Ringback.minimumOutgoingConnectingDuration,
            isPushToTalkEnabled: isPushToTalkEnabled
        )
    }

    /// Asks for the microphone first (prompting on an undecided install), and places
    /// no call the agent could not hear: a refusal is explained instead.
    func placeCall(_ agent: Agent) async {
        guard await microphone.requestAccess() else {
            Log.info(.call, "Call not placed: no microphone access")
            callRefusedForMicrophone = agent.name
            return
        }
        await callEngine.placeCall(callHost.target(for: agent))
    }

    /// The agent behind the live call, for its name, avatar, and color. nil when
    /// the call's target is unknown (the UI falls back to a generic caller).
    var activeCallAgent: Agent? {
        guard let id = callEngine.activeCall?.targetID else { return nil }
        if let cached = activeCallAgentCache, cached.id == id { return cached.agent }
        let agent = callHost.agent(id: id)
        activeCallAgentCache = (id, agent)
        return agent
    }

    @ObservationIgnored private var activeCallAgentCache: (id: UUID, agent: Agent?)?

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

        #if DEBUG
        CallTrace.startSession("launch")
        CallTrace.captureEngineLog()
        #endif

        let makeCallEngine: (CallEngineConfiguration) -> CallEngine
        let transportFactory: (TransportKind) -> CallTransport
        let simulatedCallSystem: SimulatedCallSystem?
        #if targetEnvironment(simulator)
        let system = SimulatedCallSystem()
        simulatedCallSystem = system
        makeCallEngine = { CallEngine.simulated(configuration: $0, system: system) }
        transportFactory = { _ in FakeTransport() }
        #else
        simulatedCallSystem = nil
        makeCallEngine = { CallEngine(configuration: $0) }
        transportFactory = { kind in
            let transport: CallTransport = switch kind {
            case .daily: PipecatDailyTransport()
            case .livekit: LiveKitTransport()
            case .smallwebrtc: PipecatSmallWebRTCTransport()
            }
            #if DEBUG
            CallTrace.record("transport made: \(kind.rawValue) canConnectWhileRinging=\(transport.canConnectWhileRinging)")
            #endif
            return transport
        }
        #endif

        let systemRingback = SystemRingback()
        let playerRingback = AudioPlayerRingback()
        let ringback = RouteAwareRingback(systemSound: systemRingback, audioPlayer: playerRingback)
        #if DEBUG
        systemRingback.trace = { CallTrace.record($0) }
        playerRingback.trace = { CallTrace.record($0) }
        ringback.trace = { CallTrace.record($0) }
        #endif
        let announcer = SpeechSpokenStateAnnouncer(ringback: ringback)
        let environment = AppEnvironment(
            modelContainer: container,
            keychain: KeychainService(),
            contactSync: ContactSyncService(),
            agentRepository: SwiftDataAgentRepository(context: container.mainContext),
            announcer: announcer,
            microphone: SystemMicrophonePermission(),
            transportFactory: transportFactory,
            isPushToTalkEnabled: { UserDefaults.standard.bool(forKey: SettingsStore.pushToTalkKey) },
            simulatedCallSystem: simulatedCallSystem,
            makeCallEngine: makeCallEngine
        )
        let engine = environment.callEngine
        ringback.followAudioActivation { [weak engine] in engine?.isAudioActivated ?? false }
        #if DEBUG
        environment.callHost.trace = { CallTrace.record($0) }
        announcer.trace = { CallTrace.record($0) }
        CallTraceObserver.start(engine: environment.callEngine)
        #endif
        return environment
    }

    /// The process-wide live environment. The SwiftUI `App` and the UIKit
    /// `AppDelegate` (PushKit) reach the same instance, so an inbound VoIP push
    /// routes into the same engine the UI observes.
    static let shared = live()

    /// All-fakes environment over an in-memory SwiftData store.
    static func inMemory(microphone: MicrophonePermissionProviding? = nil) -> AppEnvironment {
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: Agent.self, CallLogEntry.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        } catch {
            fatalError("Failed to build in-memory ModelContainer: \(error)")
        }
        let system = SimulatedCallSystem()
        return AppEnvironment(
            modelContainer: container,
            keychain: InMemoryKeychain(),
            contactSync: FakeContactSync(),
            agentRepository: SwiftDataAgentRepository(context: container.mainContext),
            announcer: FakeSpokenStateAnnouncer(),
            microphone: microphone ?? FakeMicrophonePermission(),
            transportFactory: { _ in FakeTransport() },
            isPushToTalkEnabled: { UserDefaults.standard.bool(forKey: SettingsStore.pushToTalkKey) },
            simulatedCallSystem: system,
            makeCallEngine: { CallEngine.simulated(configuration: $0, system: system) }
        )
    }
}
