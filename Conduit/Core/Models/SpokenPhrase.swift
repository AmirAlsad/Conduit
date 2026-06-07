//
//  SpokenPhrase.swift
//  Conduit
//
//  The short status phrases the app speaks itself — in a deliberately robotic
//  built-in voice, distinct from the agent's — so the driver has transparency
//  exactly when the agent is unreachable. `connecting` and `retrying` repeat on a
//  ~7s cadence; `connected` and `disconnected` are spoken once.
//

import Foundation

enum SpokenPhrase: String, Equatable, Sendable {
    case connecting
    case connected
    case disconnected
    case retrying

    var utterance: String {
        switch self {
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .retrying: return "Retrying connection"
        }
    }
}
