//
//  AppWiringTests.swift
//  ConduitTests
//
//  The production wiring between the engine and its host. Host tests build their
//  own harness, so without these a lost assignment (the engine's delegate, the
//  host's engine, or the save-time registrar) would leave registration silently
//  doing nothing while every other test passed.
//

import Foundation
import SwiftData
import Testing
@testable import Conduit
import ConduitCallEngine
import ConduitCallEngineTesting

@MainActor
struct AppWiringTests {

    @Test func environmentWiresTheHostToTheEngine() {
        let environment = AppEnvironment.inMemory()

        #expect(environment.callEngine.delegate === environment.callHost)
        // The host reads its VoIP token from this engine for save-time registration.
        #expect(environment.callHost.engine === environment.callEngine)
    }

    /// The configuration the app builds its engine with.
    private func appConfiguration() throws -> CallEngineConfiguration? {
        let system = SimulatedCallSystem()
        var configuration: CallEngineConfiguration?
        let container = try ModelContainer(
            for: Agent.self, CallLogEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        _ = AppEnvironment(
            modelContainer: container,
            keychain: InMemoryKeychain(),
            contactSync: FakeContactSync(),
            agentRepository: SwiftDataAgentRepository(context: container.mainContext),
            announcer: FakeSpokenStateAnnouncer(),
            microphone: FakeMicrophonePermission(),
            transportFactory: { _ in FakeTransport() },
            simulatedCallSystem: system,
            makeCallEngine: {
                configuration = $0
                return CallEngine.simulated(configuration: $0, system: system)
            }
        )
        return configuration
    }

    /// The engine holds a call connecting for the ringback's start delay and first
    /// tone, so the tone is never cut and "Connected" follows it.
    @Test func theEngineConnectsNoSoonerThanTheRingbacksFirstTone() throws {
        let configuration = try appConfiguration()
        #expect(Ringback.startDelay == .milliseconds(500))
        #expect(Ringback.toneLength == .milliseconds(2100))
        #expect(configuration?.minimumOutgoingConnectingDuration == Ringback.startDelay + Ringback.toneLength)
    }

    /// A call starts like a phone call, on the earpiece with nothing connected: the
    /// app leaves the engine's speaker default off, and the user picks the speaker.
    @Test func callsStartOnTheEarpiece() throws {
        let configuration = try #require(try appConfiguration())
        #expect(configuration.defaultsToSpeaker == false)
    }

    /// The engine's call hold is experimental (audio did not come back after a real
    /// phone call), so the app leaves it off: a phone call the user accepts ends
    /// the call, and no call is ever reported holdable.
    @Test func callsCannotBeHeld() async throws {
        let configuration = try #require(try appConfiguration())
        #expect(configuration.supportsHolding == false)

        let system = SimulatedCallSystem()
        let engine = CallEngine.simulated(configuration: configuration, system: system)
        await engine.placeCall(CallTarget(
            id: UUID(),
            displayName: "Agent",
            makeTransport: { FakeTransport() },
            connect: { _ in CallConnection(url: URL(string: "https://example.invalid/room")!, token: "t") }
        ))
        let callID = try #require(system.startedCallIDs.first)
        #expect(system.reportedSupportsHolding(callID) == false)
        #expect(!(await system.setHeldFromSystem(callID, onHold: true)))
        #expect(!engine.isOnHold)
        await engine.endCall()
    }

    @Test func launchWiresSaveTimeRegistrationToTheHost() {
        // The hosted test bundle runs inside the launched app, so the AppDelegate's
        // didFinishLaunching has already wired the shared environment.
        let environment = AppEnvironment.shared

        #expect(environment.inboundRegistrar === environment.callHost)
        #expect(environment.callEngine.delegate === environment.callHost)
        #expect(environment.callHost.engine === environment.callEngine)
    }
}
