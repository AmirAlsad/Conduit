//
//  DeepLinkParserTests.swift
//  ConduitTests
//
//  Parsing conduit://add-agent links: the QR/deep-link pairing contract. The
//  link shape is frozen against example-backend/scripts/pair.py — both sides
//  test the same URL.
//

import Foundation
import Testing
@testable import Conduit

struct DeepLinkParserTests {

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func parsesFullLink() throws {
        let link = try DeepLinkParser.parse(url(
            "conduit://add-agent?v=1&name=Live%20Agent&transport=livekit"
            + "&pair=https%3A%2F%2Fhost.example%2Fconnect%2Flive"
            + "&key=sk-123"
            + "&inbound=https%3A%2F%2Fhost.example%2Finbound%2Fregister%2Flive"
        ))
        #expect(link.name == "Live Agent")
        #expect(link.transport == .livekit)
        #expect(link.pairingEndpoint == url("https://host.example/connect/live"))
        #expect(link.apiKey == "sk-123")
        #expect(link.inboundRegistrationURL == url("https://host.example/inbound/register/live"))
    }

    @Test func keyAndInboundAreOptional() throws {
        let link = try DeepLinkParser.parse(url(
            "conduit://add-agent?v=1&name=Echo&pair=https%3A%2F%2Fhost.example%2Fconnect%2Floopback"
        ))
        #expect(link.apiKey == nil)
        #expect(link.inboundRegistrationURL == nil)
        #expect(link.transport == .daily) // default
    }

    @Test func emptyKeyReadsAsAbsent() throws {
        let link = try DeepLinkParser.parse(url(
            "conduit://add-agent?v=1&name=Echo&pair=https%3A%2F%2Fh.example%2Fc&key="
        ))
        #expect(link.apiKey == nil)
    }

    @Test func allowsHTTPForLocalDevelopment() throws {
        let link = try DeepLinkParser.parse(url(
            "conduit://add-agent?v=1&name=Dev&pair=http%3A%2F%2Flocalhost%3A8000%2Fconnect%2Floopback"
        ))
        #expect(link.pairingEndpoint.scheme == "http")
    }

    @Test func rejectsNonWebPairingEndpoint() {
        #expect(throws: DeepLinkError.invalidPairingEndpoint) {
            try DeepLinkParser.parse(url(
                "conduit://add-agent?v=1&name=X&pair=javascript%3Aalert(1)"
            ))
        }
    }

    @Test func rejectsWrongScheme() {
        #expect(throws: DeepLinkError.unsupportedScheme) {
            try DeepLinkParser.parse(url("https://example.com/add-agent?v=1&name=X&pair=https%3A%2F%2Fh%2Fc"))
        }
    }

    @Test func rejectsUnknownAction() {
        #expect(throws: DeepLinkError.unsupportedAction("call")) {
            try DeepLinkParser.parse(url("conduit://call?v=1&name=X&pair=https%3A%2F%2Fh.example%2Fc"))
        }
    }

    @Test func rejectsFutureVersion() {
        #expect(throws: DeepLinkError.unsupportedVersion("2")) {
            try DeepLinkParser.parse(url("conduit://add-agent?v=2&name=X&pair=https%3A%2F%2Fh.example%2Fc"))
        }
    }

    @Test func rejectsMissingName() {
        #expect(throws: DeepLinkError.missingName) {
            try DeepLinkParser.parse(url("conduit://add-agent?v=1&pair=https%3A%2F%2Fh.example%2Fc"))
        }
        #expect(throws: DeepLinkError.missingName) {
            try DeepLinkParser.parse(url("conduit://add-agent?v=1&name=%20&pair=https%3A%2F%2Fh.example%2Fc"))
        }
    }

    @Test func rejectsMissingPairingEndpoint() {
        #expect(throws: DeepLinkError.missingPairingEndpoint) {
            try DeepLinkParser.parse(url("conduit://add-agent?v=1&name=X"))
        }
    }

    @Test func rejectsUnknownTransport() {
        #expect(throws: DeepLinkError.invalidTransport("webrtc")) {
            try DeepLinkParser.parse(url(
                "conduit://add-agent?v=1&name=X&transport=webrtc&pair=https%3A%2F%2Fh.example%2Fc"
            ))
        }
    }

    @Test func rejectsInvalidInboundURL() {
        #expect(throws: DeepLinkError.invalidInboundURL) {
            try DeepLinkParser.parse(url(
                "conduit://add-agent?v=1&name=X&pair=https%3A%2F%2Fh.example%2Fc&inbound=notaurl"
            ))
        }
    }

    @Test func rejectsOverlongURL() {
        let long = "conduit://add-agent?v=1&name=X&pair=https%3A%2F%2Fh.example%2Fc&key="
            + String(repeating: "a", count: DeepLinkParser.maxURLLength)
        #expect(throws: DeepLinkError.tooLong) {
            try DeepLinkParser.parse(url(long))
        }
    }

    @Test func capsOverlongNames() throws {
        let name = String(repeating: "n", count: 500)
        let link = try DeepLinkParser.parse(url(
            "conduit://add-agent?v=1&name=\(name)&pair=https%3A%2F%2Fh.example%2Fc"
        ))
        #expect(link.name.count == DeepLinkParser.maxNameLength)
    }
}
