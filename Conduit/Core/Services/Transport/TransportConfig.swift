//
//  TransportConfig.swift
//  Conduit
//
//  Everything a transport needs to connect, parsed from an `Agent` plus its
//  Keychain credential at call time. Transport-neutral; the credential is read
//  from the Keychain only here and never persisted on the agent.
//
//  Two connection modes:
//  - Pairing: `pairingEndpoint` is POSTed (with `token` as the bearer API key) for
//    a fresh room + token per call. The endpoint identifies the agent.
//  - Direct: `url` is the room URL and `token` the room token.
//

import Foundation

struct TransportConfig: Equatable, Sendable {
    let kind: TransportKind
    let url: URL?
    let token: String
    let pairingEndpoint: URL?

    init(
        kind: TransportKind,
        url: URL? = nil,
        token: String,
        pairingEndpoint: URL? = nil
    ) {
        self.kind = kind
        self.url = url
        self.token = token
        self.pairingEndpoint = pairingEndpoint
    }
}
