//
//  PairingClientTests.swift
//  ConduitTests
//
//  The pairing-response parsing — the engine nests credentials under `connection`,
//  which is what the SDK's built-in pairing decoder couldn't handle. A flat shape,
//  a camelCase room key, and a `url` key (LiveKit token servers' usual name for
//  the server URL) are accepted as fallbacks.
//

import Foundation
import Testing
@testable import Conduit

struct PairingClientTests {
    @Test func parsesNestedConnectionShape() throws {
        let json = Data(#"{"connection": {"room_url": "https://x.daily.co/abc", "token": "tok123"}}"#.utf8)
        let creds = try PairingClient.parse(json)
        #expect(creds.roomURL.absoluteString == "https://x.daily.co/abc")
        #expect(creds.token == "tok123")
    }

    @Test func parsesFlatShape() throws {
        let json = Data(#"{"room_url": "https://x.daily.co/flat", "token": "t"}"#.utf8)
        let creds = try PairingClient.parse(json)
        #expect(creds.roomURL.absoluteString == "https://x.daily.co/flat")
        #expect(creds.token == "t")
    }

    @Test func parsesCamelCaseRoomKey() throws {
        let json = Data(#"{"connection": {"roomUrl": "https://x.daily.co/camel", "token": "t"}}"#.utf8)
        let creds = try PairingClient.parse(json)
        #expect(creds.roomURL.absoluteString == "https://x.daily.co/camel")
    }

    @Test func parsesUrlKeyFallbackFlat() throws {
        let json = Data(#"{"url": "wss://x.livekit.cloud", "token": "jwt"}"#.utf8)
        let creds = try PairingClient.parse(json)
        #expect(creds.roomURL.absoluteString == "wss://x.livekit.cloud")
        #expect(creds.token == "jwt")
    }

    @Test func parsesUrlKeyFallbackNested() throws {
        let json = Data(#"{"connection": {"url": "wss://x.livekit.cloud", "token": "jwt"}}"#.utf8)
        let creds = try PairingClient.parse(json)
        #expect(creds.roomURL.absoluteString == "wss://x.livekit.cloud")
    }

    @Test func roomUrlWinsOverUrl() throws {
        let json = Data(#"{"room_url": "wss://canonical.livekit.cloud", "url": "wss://alias.livekit.cloud", "token": "t"}"#.utf8)
        let creds = try PairingClient.parse(json)
        #expect(creds.roomURL.absoluteString == "wss://canonical.livekit.cloud")
    }

    @Test func parsesSmallWebRTCOfferShape() throws {
        // smallwebrtc pairing: room_url is the engine's plain-http LAN offer
        // endpoint, token a short-lived bearer for it.
        let json = Data(#"{"connection": {"room_url": "http://192.168.1.50:8000/webrtc/loopback/offer", "token": "eph-1"}}"#.utf8)
        let creds = try PairingClient.parse(json)
        #expect(creds.roomURL.absoluteString == "http://192.168.1.50:8000/webrtc/loopback/offer")
        #expect(creds.token == "eph-1")
    }

    @Test func throwsOnMissingToken() {
        let json = Data(#"{"connection": {"room_url": "https://x.daily.co/abc"}}"#.utf8)
        #expect(throws: PairingError.missingCredentials) {
            try PairingClient.parse(json)
        }
    }

    @Test func throwsOnGarbage() {
        let json = Data("not json".utf8)
        #expect(throws: PairingError.invalidResponse) {
            try PairingClient.parse(json)
        }
    }
}
