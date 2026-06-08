//
//  KeychainServiceTests.swift
//  ConduitTests
//
//  Round-trips the real `KeychainService` against the simulator keychain. Each
//  test uses a unique service namespace so parallel runs (and reruns) never
//  collide and nothing leaks into the app's real token namespace.
//

import Foundation
import Testing
@testable import Conduit

struct KeychainServiceTests {
    private let service = "com.amiralsad.Conduit.tests.\(UUID().uuidString)"
    private let ref = KeychainTokenRef(agentID: UUID())

    private func makeKeychain() -> KeychainService { KeychainService(service: service) }

    @Test func storesAndReadsBackToken() throws {
        let keychain = makeKeychain()
        defer { try? keychain.deleteToken(for: ref) }

        try keychain.setToken("secret-token", for: ref)
        #expect(try keychain.token(for: ref) == "secret-token")
    }

    @Test func missingTokenReturnsNil() throws {
        let keychain = makeKeychain()
        #expect(try keychain.token(for: KeychainTokenRef(agentID: UUID())) == nil)
    }

    @Test func setOverwritesExistingToken() throws {
        let keychain = makeKeychain()
        defer { try? keychain.deleteToken(for: ref) }

        try keychain.setToken("first", for: ref)
        try keychain.setToken("second", for: ref)
        #expect(try keychain.token(for: ref) == "second")
    }

    @Test func deleteRemovesToken() throws {
        let keychain = makeKeychain()

        try keychain.setToken("to-delete", for: ref)
        try keychain.deleteToken(for: ref)
        #expect(try keychain.token(for: ref) == nil)
    }

    @Test func deleteMissingTokenDoesNotThrow() throws {
        let keychain = makeKeychain()
        try keychain.deleteToken(for: KeychainTokenRef(agentID: UUID()))
    }

    @Test func tokensAreIsolatedByAccount() throws {
        let keychain = makeKeychain()
        let refA = KeychainTokenRef(agentID: UUID())
        let refB = KeychainTokenRef(agentID: UUID())
        defer {
            try? keychain.deleteToken(for: refA)
            try? keychain.deleteToken(for: refB)
        }

        try keychain.setToken("a", for: refA)
        try keychain.setToken("b", for: refB)
        #expect(try keychain.token(for: refA) == "a")
        #expect(try keychain.token(for: refB) == "b")
    }
}
