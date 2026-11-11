//
//  CallConnection.swift
//  Conduit
//
//  The already-resolved room a transport joins: the room (or offer) URL and its
//  token. Credentials are resolved before `connect` — the transport never pairs.
//

import Foundation

struct CallConnection: Equatable, Sendable {
    let url: URL
    let token: String?
}
