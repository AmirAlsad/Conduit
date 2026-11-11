//
//  AudioRouteKindTests.swift
//  ConduitTests
//
//  How the in-call route picker labels and orders each route kind
//  (`AudioRouteKind+Display`). The device-id mapping itself is tested in the
//  ConduitCallEngine package.
//

import Testing
@testable import Conduit
import ConduitCallEngine

struct AudioRouteKindTests {
    @Test func displayNamesAreFriendly() {
        #expect(AudioRouteKind.receiver.displayName == "iPhone")
        #expect(AudioRouteKind.speaker.displayName == "Speaker")
        #expect(AudioRouteKind.bluetooth.displayName == "Bluetooth")
    }

    @Test func sortOrderIsPhoneThenSpeakerThenExternal() {
        #expect(AudioRouteKind.receiver.sortRank < AudioRouteKind.speaker.sortRank)
        #expect(AudioRouteKind.speaker.sortRank < AudioRouteKind.bluetooth.sortRank)
    }
}
