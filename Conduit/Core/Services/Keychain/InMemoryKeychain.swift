//
//  InMemoryKeychain.swift
//  Conduit
//
//  In-app fake conforming to `KeychainStoring`. A lock-guarded dictionary so the
//  add-agent → test-connection → call path runs in the simulator with no real
//  keychain.
//

import Foundation

final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    func setToken(_ token: String, for ref: KeychainTokenRef) throws {
        lock.withLock { store[ref.account] = token }
    }

    func token(for ref: KeychainTokenRef) throws -> String? {
        lock.withLock { store[ref.account] }
    }

    func deleteToken(for ref: KeychainTokenRef) throws {
        lock.withLock { _ = store.removeValue(forKey: ref.account) }
    }
}
