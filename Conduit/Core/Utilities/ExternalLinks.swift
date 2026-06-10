//
//  ExternalLinks.swift
//  Conduit
//
//  The user-facing documentation site (GitHub Pages, built from docs/ by
//  mkdocs.yml). Paths must match the site's nav slugs — mkdocs serves each
//  page as a directory URL, e.g. docs/connect-your-agent.md → /connect-your-agent/.
//

import Foundation

enum ExternalLinks {
    static let docsBase = URL(string: "https://amiralsad.github.io/Conduit")!
    static let connectYourAgent = docsBase.appending(path: "connect-your-agent/")
    static let inboundCalls = docsBase.appending(path: "INBOUND_CALLS/")
    static let usingConduit = docsBase.appending(path: "using-conduit/")

    // Fragment links are composed as strings — appending(path:) would
    // percent-encode the '#'. Anchors verified against the rendered site.
    static let pairingDocs = URL(string: connectYourAgent.absoluteString + "#pairing-recommended")!
    static let directRoomDocs = URL(string: connectYourAgent.absoluteString + "#direct-room-advanced")!
    static let pushToTalkDocs = URL(string: usingConduit.absoluteString + "#push-to-talk")!
    static let dailyAudioDocs = URL(string: usingConduit.absoluteString + "#daily-audio-routing")!
    static let contactMirrorDocs = URL(string: usingConduit.absoluteString + "#add-to-contacts")!
}
