//
//  ContactsMirroring.swift
//  Conduit
//
//  The seam over the optional system-contact mirror. The real `ContactsService`
//  (WS-4) uses `CNContactStore`; it owns the lifecycle edges — permission asked
//  only when the toggle is flipped on, the mirror updated on edit and removed on
//  delete (with the known caveat that app-created contacts can linger after the
//  app is uninstalled).
//

import Foundation

protocol ContactsMirroring: Sendable {
    func authorizationStatus() -> ContactsAuthStatus
    func requestAccess() async -> Bool
    /// Create or update the mirrored contact for an agent.
    func upsertMirror(for info: AgentMirrorInfo) async throws
    func removeMirror(agentID: UUID) async throws
}
