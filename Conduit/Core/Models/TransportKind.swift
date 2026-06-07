//
//  TransportKind.swift
//  Conduit
//
//  Which WebRTC transport carries a call. The agent is reached the same way
//  regardless; only the connection vocabulary differs. Daily ships first;
//  LiveKit is a fast-follow behind the same `Transport` protocol.
//

import Foundation

enum TransportKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case daily
    case livekit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .livekit: return "LiveKit"
        }
    }
}
