//
//  CallDirection.swift
//  Conduit
//
//  Which way a call was initiated. Outgoing is the user calling an agent; incoming
//  is the agent's own server ringing the user via a VoIP push (see VoIPPushService).
//  Modeled as an enum so the call log stays explicit.
//

import Foundation

enum CallDirection: String, Codable, Sendable {
    case outgoing
    case incoming
}
