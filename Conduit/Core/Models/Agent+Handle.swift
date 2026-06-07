//
//  Agent+Handle.swift
//  Conduit
//
//  Minting and use of the agent's synthetic call handle.
//

import Foundation

extension Agent {
    /// The handle a call to this agent is placed against.
    var callHandle: CallHandle { CallHandle(value: syntheticEmail) }

    /// Mints the stable synthetic handle used as the call's email-type CXHandle.
    ///
    /// Email type (not generic) is deliberate: a generic handle makes Siri read
    /// the raw alphanumeric ID aloud even when a caller name is set. The reserved
    /// `.invalid` TLD guarantees the address can never resolve to a real mailbox.
    static func makeSyntheticEmail(name: String, id: UUID) -> String {
        let slug = slugify(name)
        let shortID = id.uuidString.prefix(8).lowercased()
        let prefix = slug.isEmpty ? "agent" : slug
        return "\(prefix)-\(shortID).agent.conduit.invalid"
    }

    private static func slugify(_ name: String) -> String {
        let mapped = name.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(32))
    }
}
