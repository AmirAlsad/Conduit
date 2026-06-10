//
//  TransportKind.swift
//  Conduit
//
//  Which WebRTC transport carries a call. The agent is reached the same way
//  regardless; only the connection vocabulary differs. Daily and LiveKit ride
//  their clouds; SmallWebRTC is peer-to-peer with the user's own server (LAN /
//  self-hosted — no account, no cloud). Raw values are persisted in SwiftData
//  and ride the conduit:// deep-link contract — never rename them.
//

import Foundation

enum TransportKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case daily
    case livekit
    case smallwebrtc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .livekit: return "LiveKit"
        case .smallwebrtc: return "SmallWebRTC"
        }
    }
}
