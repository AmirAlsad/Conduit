//
//  KeychainError.swift
//  Conduit
//
//  Errors surfaced by `KeychainService`. `unexpected` carries the raw
//  `OSStatus` from the Security framework for diagnosis via `Log`.
//

import Foundation

enum KeychainError: Error, Equatable {
    case encodingFailed
    case decodingFailed
    case unexpected(OSStatus)
}
