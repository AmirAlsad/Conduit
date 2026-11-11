//
//  AppWiringTests.swift
//  ConduitTests
//
//  The production wiring between the engine and its host. Host tests build their
//  own harness, so without these a lost assignment (the engine's delegate, the
//  host's engine, or the save-time registrar) would leave registration silently
//  doing nothing while every other test passed.
//

import Testing
@testable import Conduit
import ConduitCallEngine

@MainActor
struct AppWiringTests {

    @Test func environmentWiresTheHostToTheEngine() {
        let environment = AppEnvironment.inMemory()

        #expect(environment.callEngine.delegate === environment.callHost)
        // The host reads its VoIP token from this engine for save-time registration.
        #expect(environment.callHost.engine === environment.callEngine)
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
