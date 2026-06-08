//
//  PairingCredentials.swift
//  Conduit
//
//  The room URL + token a pairing endpoint hands back for a single call.
//

import Foundation

struct PairingCredentials: Equatable, Sendable {
    let roomURL: URL
    let token: String
}
