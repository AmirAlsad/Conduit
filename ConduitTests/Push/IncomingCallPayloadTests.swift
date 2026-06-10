//
//  IncomingCallPayloadTests.swift
//  ConduitTests
//
//  Parsing the VoIP push dictionary into a typed payload: required agent id, the
//  optional call id, and the optional inline room credentials (the hybrid path).
//

import Foundation
import Testing
@testable import Conduit

@MainActor
struct IncomingCallPayloadTests {

    @Test func parsesAgentAndCallID() throws {
        let agentID = UUID()
        let callID = UUID()
        let payload = try #require(IncomingCallPayload(dictionary: [
            "agent_id": agentID.uuidString,
            "call_id": callID.uuidString,
        ]))
        #expect(payload.agentID == agentID)
        #expect(payload.callID == callID)
        #expect(payload.inlineCredentials == nil)
    }

    @Test func parsesInlineCredentials() throws {
        let payload = try #require(IncomingCallPayload(dictionary: [
            "agent_id": UUID().uuidString,
            "call_id": UUID().uuidString,
            "room_url": "https://example.daily.co/room",
            "token": "room-token",
        ]))
        let creds = try #require(payload.inlineCredentials)
        #expect(creds.roomURL == URL(string: "https://example.daily.co/room"))
        #expect(creds.token == "room-token")
    }

    @Test func parsesStatusURL() throws {
        let payload = try #require(IncomingCallPayload(dictionary: [
            "agent_id": UUID().uuidString,
            "status_url": "https://engine.example.com/inbound/status/live",
        ]))
        #expect(payload.statusURL == URL(string: "https://engine.example.com/inbound/status/live"))
    }

    @Test func statusURLAbsentIsNil() throws {
        let payload = try #require(IncomingCallPayload(dictionary: ["agent_id": UUID().uuidString]))
        #expect(payload.statusURL == nil)
    }

    @Test func mintsCallIDWhenAbsent() throws {
        let payload = try #require(IncomingCallPayload(dictionary: ["agent_id": UUID().uuidString]))
        #expect(payload.inlineCredentials == nil) // call id minted; no inline creds
    }

    @Test func rejectsMissingAgentID() {
        #expect(IncomingCallPayload(dictionary: ["call_id": UUID().uuidString]) == nil)
    }

    @Test func rejectsInvalidAgentID() {
        #expect(IncomingCallPayload(dictionary: ["agent_id": "not-a-uuid"]) == nil)
    }

    @Test func ignoresInlineCredsWhenTokenMissing() throws {
        let payload = try #require(IncomingCallPayload(dictionary: [
            "agent_id": UUID().uuidString,
            "room_url": "https://example.daily.co/room",
        ]))
        #expect(payload.inlineCredentials == nil)
    }
}
