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
}
