//
//  FakeContactsMirror.swift
//  Conduit
//
//  In-app fake conforming to `ContactsMirroring`. Records mirror state so the
//  add/edit flow runs in the simulator without touching the address book.
//

import Foundation

final class FakeContactsMirror: ContactsMirroring, @unchecked Sendable {
    private let lock = NSLock()
    private var status: ContactsAuthStatus
    private var mirrored: [UUID: AgentMirrorInfo] = [:]

    /// Whether `requestAccess()` grants permission.
    var grantsAccess: Bool

    init(status: ContactsAuthStatus = .notDetermined, grantsAccess: Bool = true) {
        self.status = status
        self.grantsAccess = grantsAccess
    }

    func authorizationStatus() -> ContactsAuthStatus {
        lock.withLock { status }
    }

    func requestAccess() async -> Bool {
        lock.withLock {
            if grantsAccess { status = .authorized }
            return grantsAccess
        }
    }

    func upsertMirror(for info: AgentMirrorInfo) async throws {
        lock.withLock { mirrored[info.id] = info }
    }

    func removeMirror(agentID: UUID) async throws {
        lock.withLock { _ = mirrored.removeValue(forKey: agentID) }
    }

    /// Test inspection: the mirror currently held for an agent, if any.
    func mirror(for agentID: UUID) -> AgentMirrorInfo? {
        lock.withLock { mirrored[agentID] }
    }
}
