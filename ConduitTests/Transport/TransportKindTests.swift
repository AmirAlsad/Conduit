//
//  TransportKindTests.swift
//  ConduitTests
//
//  Raw values are persisted in SwiftData and ride the conduit:// deep-link
//  contract (and the engine's Transport literal) — these lock them down.
//

import Testing
@testable import Conduit

struct TransportKindTests {
    @Test func rawValuesAreFrozen() {
        #expect(TransportKind.daily.rawValue == "daily")
        #expect(TransportKind.livekit.rawValue == "livekit")
        #expect(TransportKind.smallwebrtc.rawValue == "smallwebrtc")
    }

    @Test func displayNames() {
        #expect(TransportKind.smallwebrtc.displayName == "SmallWebRTC")
    }
}
