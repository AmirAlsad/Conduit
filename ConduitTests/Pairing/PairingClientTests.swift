//
//  PairingClientTests.swift
//  ConduitTests
//
//  The pairing-response parsing — the engine nests credentials under `connection`,
//  which is what the SDK's built-in pairing decoder couldn't handle. A flat shape
//  and camelCase room key are accepted as fallbacks.
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
