//
//  TransportConfig.swift
//  Conduit
//
//  Everything a transport needs to connect, parsed from an `Agent` plus its
//  Keychain credential at call time. Transport-neutral; the credential is read
//  from the Keychain only here and never persisted on the agent.
//
//  Two connection modes:
//  - Direct: `url` is the room URL and `token` the room token.
//  - Pairing: `pairingEndpoint` is POSTed (with `token` as the bearer API key and
//    `pairingAgentID` as the agent selector) for a fresh room + token per call.
//

import Foundation

struct TransportConfig: Equatable, Sendable {
    let kind: TransportKind
    let url: URL?
    let token: String
    let pairingEndpoint: URL?
    let pairingAgentID: String?

    init(
        kind: TransportKind,
        url: URL? = nil,
        token: String,
        pairingEndpoint: URL? = nil,
        pairingAgentID: String? = nil
    ) {
        self.kind = kind
        self.url = url
        self.token = token
        self.pairingEndpoint = pairingEndpoint
        self.pairingAgentID = pairingAgentID
    }
}
