//
//  KeychainStoring.swift
//  Conduit
//
//  The seam over secure token storage. The real `KeychainService` (WS-4) uses the
//  Security framework with `kSecAttrAccessibleAfterFirstUnlock` so a call can
//  connect while the device is locked; `InMemoryKeychain` backs tests and previews.
//

import Foundation

protocol KeychainStoring: Sendable {
    func setToken(_ token: String, for ref: KeychainTokenRef) throws
    func token(for ref: KeychainTokenRef) throws -> String?
    func deleteToken(for ref: KeychainTokenRef) throws
}
