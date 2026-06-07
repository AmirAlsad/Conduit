//
//  CallDirection.swift
//  Conduit
//
//  Every call is user-initiated (outgoing) — there is no incoming path, by
//  design (no PushKit). Modeled as an enum so the call log stays explicit.
//

import Foundation

enum CallDirection: String, Codable, Sendable {
    case outgoing
}
