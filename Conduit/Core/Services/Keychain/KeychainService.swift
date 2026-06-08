//
//  KeychainService.swift
//  Conduit
//
//  Real `KeychainStoring` over the Security framework. Tokens are stored as
//  generic-password items keyed by (service, account); `account` is the
//  `KeychainTokenRef` minted from the agent id, so the token never lives in
//  SwiftData, a contact, a log, or git.
//
//  Accessibility is `kSecAttrAccessibleAfterFirstUnlock` — the token survives a
//  reboot's first unlock and remains readable while the screen is locked, so a
//  call can connect from the lock screen / CarPlay. It is NOT
//  `…ThisDeviceOnly`-with-no-lock: we deliberately don't expose tokens before
//  first unlock.
//

import Foundation
import Security

struct KeychainService: KeychainStoring {
    private let service: String

    init(service: String = "com.amiralsad.Conduit.tokens") {
        self.service = service
    }

    func setToken(_ token: String, for ref: KeychainTokenRef) throws {
        guard let data = token.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let query = baseQuery(for: ref)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpected(updateStatus) }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpected(addStatus) }
    }

    func token(for ref: KeychainTokenRef) throws -> String? {
        var query = baseQuery(for: ref)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpected(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return token
    }

    func deleteToken(for ref: KeychainTokenRef) throws {
        let status = SecItemDelete(baseQuery(for: ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpected(status)
        }
    }

    private func baseQuery(for ref: KeychainTokenRef) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref.account,
        ]
    }
}
