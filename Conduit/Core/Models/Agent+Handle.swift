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

    /// Mints the synthetic handle used as the call's email-type CXHandle and the
    /// matching contact's email. Minted once at creation and stored, so it's stable
    /// across renames.
    ///
    /// Email type (not generic) is deliberate: a generic handle makes Siri read the
    /// raw handle aloud even when a caller name is set. The reserved `.invalid` TLD
    /// guarantees the address can never resolve to a real mailbox. Kept as a clean
    /// `<slug>@conduit.invalid` for a tidy contact card — two agents sharing a name
    /// would collide on the handle (only a cosmetic native-screen photo mix-up; the
    /// agents themselves are keyed by `id`).
    static func makeSyntheticEmail(name: String) -> String {
        let slug = slugify(name)
        return "\(slug.isEmpty ? "agent" : slug)@conduit.invalid"
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
