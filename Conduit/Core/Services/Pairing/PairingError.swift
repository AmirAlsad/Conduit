//
//  PairingError.swift
//  Conduit
//
//  Failures from resolving a pairing endpoint into call credentials.
//

import Foundation

enum PairingError: Error, Equatable {
    case invalidResponse
    case unauthorized
    case server(Int)
    case missingCredentials
}
