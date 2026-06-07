//
//  TransportConfig.swift
//  Conduit
//
//  Everything a transport needs to connect, parsed from an `Agent` plus its
//  Keychain token at call time. Transport-neutral; the token is read from the
//  Keychain only here and never persisted on the agent.
//

import Foundation

struct TransportConfig: Equatable, Sendable {
    let kind: TransportKind
    let url: URL
    let token: String
    let pairingEndpoint: URL?

    init(kind: TransportKind, url: URL, token: String, pairingEndpoint: URL? = nil) {
        self.kind = kind
        self.url = url
        self.token = token
        self.pairingEndpoint = pairingEndpoint
    }
}
