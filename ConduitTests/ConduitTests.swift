//
//  ConduitTests.swift
//  ConduitTests
//
//  Unit tests run on the simulator (iOS 18.6 pin — see CLAUDE.md). This is where
//  most logic lives: the call state machine, connection/transport parsing, and
//  error handling test against fakes here. The live CallKit + WebRTC call is
//  device-only (see voice-agent-callkit-plan.md, "Testing and the iteration loop").
//

import Testing
@testable import Conduit

struct ConduitTests {

    @Test func appLaunchesWithRootView() async throws {
        // Smoke test: a placeholder so the suite is green from day one.
        // Replace with real logic tests as features land.
        #expect(Bool(true))
    }

}
