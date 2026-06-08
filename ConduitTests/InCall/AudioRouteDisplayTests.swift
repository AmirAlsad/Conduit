//
//  AudioRouteDisplayTests.swift
//  ConduitTests
//
//  The raw-device-name → friendly label / icon / sort-order mapping for the
//  in-call route menu.
//

import Testing
@testable import Conduit

struct AudioRouteDisplayTests {
    @Test(arguments: [
        ("Built-in Speaker and Mic", "Speaker"),
        ("Built-in Earpiece in Mic", "iPhone"),
        ("Wired Headphones", "Headphones"),
        ("Bluetooth", "Bluetooth"),
        ("AirPods Pro", "AirPods Pro"),
    ])
    func nameMapsToFriendlyLabel(raw: String, expected: String) {
        #expect(AudioRouteDisplay.name(for: raw) == expected)
    }

    @Test func iconsMatchRouteKind() {
        #expect(AudioRouteDisplay.icon(for: "Built-in Speaker and Mic") == "speaker.wave.2.fill")
        #expect(AudioRouteDisplay.icon(for: "Built-in Earpiece in Mic") == "iphone")
        #expect(AudioRouteDisplay.icon(for: "AirPods Pro") == "airpods")
    }

    @Test func rankOrdersPhoneThenSpeakerThenExternal() {
        #expect(AudioRouteDisplay.rank(for: "Built-in Earpiece in Mic") == 0)
        #expect(AudioRouteDisplay.rank(for: "Built-in Speaker and Mic") == 1)
        #expect(AudioRouteDisplay.rank(for: "AirPods Pro") == 2)
    }
}
