//
//  CallOutcome.swift
//  Conduit
//
//  How a call finished, as persisted in the call log. `failed` is what Recents
//  renders red (bad token, agent offline, lost connection).
//

import Foundation

enum CallOutcome: String, Codable, Sendable {
    case completed
    case failed
    case declined
    case noAnswer
    case canceled
}
