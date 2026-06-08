//
//  FakeContactSync.swift
//  Conduit
//
//  In-app fake `ContactSyncing` for the unit suite and previews — records sync
//  calls without touching the address book, so the "sync only a linked agent on
//  save" decision is testable at sim speed.
//

import Foundation

final class FakeContactSync: ContactSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(info: AgentMirrorInfo, contactIdentifier: String)] = []

    /// What `sync` returns (simulate access granted/denied).
    var result: Bool

    init(result: Bool = true) {
        self.result = result
    }

    func sync(_ info: AgentMirrorInfo, contactIdentifier: String) async -> Bool {
        lock.withLock { calls.append((info, contactIdentifier)) }
        return result
    }

    /// Test inspection.
    var syncCount: Int { lock.withLock { calls.count } }
    var lastSync: (info: AgentMirrorInfo, contactIdentifier: String)? {
        lock.withLock { calls.last }
    }
}
