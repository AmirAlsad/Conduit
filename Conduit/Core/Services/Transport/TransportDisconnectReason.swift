//
//  TransportDisconnectReason.swift
//  Conduit
//
//  Why the transport disconnected. The coordinator branches on this: a
//  `networkDropped` is a candidate for reconnection, while `authFailed` is a
//  terminal red failure. Conflating them would turn a recoverable road drop
//  into a dead call.
//

import Foundation

enum TransportDisconnectReason: Equatable, Sendable {
    case requestedByUser
    case networkDropped
    case authFailed
    case botLeft
    case unknown
}
