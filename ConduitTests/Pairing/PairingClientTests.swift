//
//  PairingClientTests.swift
//  ConduitTests
//
//  The pairing-response parsing — the engine nests credentials under `connection`,
//  which is what the SDK's built-in pairing decoder couldn't handle. A flat shape,
//  a camelCase room key, and a `url` key (LiveKit token servers' usual name for
//  the server URL) are accepted as fallbacks. And the request body: `transport`
//  alone for an ordinary call, plus `ring` for a request made while the phone
//  rings.
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

    // MARK: - Request body

    private static let callID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    /// Resolve against a recorder (which answers an empty 200, so parsing fails)
    /// and return the JSON body that was sent.
    private func sentBody(ring: PairingRing?) async throws -> [String: Any] {
        let endpoint = RecordingURLProtocol.uniqueEndpoint(path: "/connect/live")
        await #expect(throws: PairingError.invalidResponse) {
            try await PairingClient.resolve(
                endpoint: endpoint, apiKey: "key", transport: .livekit, ring: ring,
                session: RecordingURLProtocol.session()
            )
        }
        let host = try #require(endpoint.host())
        let request = try #require(RecordingURLProtocol.requests(host: host).first)
        #expect(request.method == "POST")
        #expect(request.headers["Authorization"] == "Bearer key")
        let json = try JSONSerialization.jsonObject(with: request.body)
        return try #require(json as? [String: Any])
    }

    @Test func anOrdinaryRequestSendsTheTransportAndTheCallSignals() async throws {
        let body = try await sentBody(ring: nil)
        #expect(body.keys.sorted() == ["call_signals", "transport"])
        #expect(body["transport"] as? String == "livekit")
        // The backend's agent waits for call-connected only from an app that lists it.
        #expect(body["call_signals"] as? [String] == ["call-connected"])
    }

    @Test(arguments: [false, true])
    func aRingingRequestAddsTheRing(joinsBeforeAnswer: Bool) async throws {
        let body = try await sentBody(ring: PairingRing(callID: Self.callID, joinsBeforeAnswer: joinsBeforeAnswer))
        #expect(body.keys.sorted() == ["call_signals", "ring", "transport"])
        #expect(body["transport"] as? String == "livekit")
        let ring = try #require(body["ring"] as? [String: Any])
        #expect(ring.keys.sorted() == ["call_id", "joins_before_answer"])
        #expect(ring["call_id"] as? String == "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        #expect(ring["joins_before_answer"] as? Bool == joinsBeforeAnswer)
    }
}
