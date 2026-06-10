//
//  DeepLinkParser.swift
//  Conduit
//
//  Parses conduit:// links into a pre-filled Add Agent request:
//
//      conduit://add-agent?v=1&name=Live&transport=livekit
//          &pair=<pct-encoded URL>[&key=…][&inbound=<pct-encoded URL>]
//
//  The host is the action and `v` pins the parameter contract, so future link
//  kinds/versions fail loudly on old builds instead of mis-parsing. The link
//  may carry the agent's API key — callers must never log the URL or the key.
//

import Foundation

struct AgentDeepLink: Equatable, Sendable {
    let name: String
    let transport: TransportKind
    let pairingEndpoint: URL
    let apiKey: String?
    let inboundRegistrationURL: URL?
}

enum DeepLinkError: Error, Equatable {
    case tooLong
    case unsupportedScheme
    case unsupportedAction(String)
    case unsupportedVersion(String)
    case missingName
    case missingPairingEndpoint
    case invalidPairingEndpoint
    case invalidInboundURL
    case invalidTransport(String)
}

enum DeepLinkParser {
    static let maxURLLength = 8_192
    static let maxNameLength = 120

    static func parse(_ url: URL) throws -> AgentDeepLink {
        guard url.absoluteString.count <= maxURLLength else { throw DeepLinkError.tooLong }
        guard url.scheme?.lowercased() == "conduit" else { throw DeepLinkError.unsupportedScheme }
        let action = url.host()?.lowercased() ?? ""
        guard action == "add-agent" else { throw DeepLinkError.unsupportedAction(action) }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        let version = value("v") ?? "1"
        guard version == "1" else { throw DeepLinkError.unsupportedVersion(version) }

        guard let rawName = value("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty
        else { throw DeepLinkError.missingName }
        let name = String(rawName.prefix(maxNameLength))

        let transportRaw = value("transport") ?? TransportKind.daily.rawValue
        guard let transport = TransportKind(rawValue: transportRaw) else {
            throw DeepLinkError.invalidTransport(transportRaw)
        }

        guard let pairRaw = value("pair") else { throw DeepLinkError.missingPairingEndpoint }
        guard let pairingEndpoint = Self.webURL(pairRaw) else {
            throw DeepLinkError.invalidPairingEndpoint
        }

        var inboundURL: URL?
        if let inboundRaw = value("inbound") {
            guard let parsed = Self.webURL(inboundRaw) else { throw DeepLinkError.invalidInboundURL }
            inboundURL = parsed
        }

        let key = value("key").flatMap { $0.isEmpty ? nil : $0 }
        return AgentDeepLink(
            name: name,
            transport: transport,
            pairingEndpoint: pairingEndpoint,
            apiKey: key,
            inboundRegistrationURL: inboundURL
        )
    }

    /// http(s) with a non-empty host — the same posture as the agent form
    /// (plain http stays allowed for localhost development).
    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}
