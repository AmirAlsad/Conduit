//
//  PairingClient.swift
//  Conduit
//
//  Resolves a bring-your-own pairing endpoint into a fresh room + token for one
//  call: POST the endpoint with the API key as a bearer and `{transport}`, then
//  read the credentials. The endpoint itself identifies the agent (one endpoint
//  per agent), so no agent id is sent. The reference engine nests credentials
//  under `connection` (which is why the SDK's built-in pairing decoder choked); a
//  flat shape is also accepted. This talks to the USER's own server — there is no
//  backend of ours.
//

import Foundation

enum PairingClient {
    static func resolve(
        endpoint: URL,
        apiKey: String,
        transport: TransportKind,
        session: URLSession = .shared
    ) async throws -> PairingCredentials {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: String] = ["transport": transport.rawValue]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PairingError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw PairingError.unauthorized }
            throw PairingError.server(http.statusCode)
        }
        return try parse(data)
    }

    /// Extract the room URL + token. Accepts the engine's nested
    /// `{ "connection": { "room_url", "token" } }` and a flat
    /// `{ "room_url" | "roomUrl", "token" }` fallback.
    static func parse(_ data: Data) throws -> PairingCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PairingError.invalidResponse
        }
        let source = (root["connection"] as? [String: Any]) ?? root
        let roomString = (source["room_url"] as? String) ?? (source["roomUrl"] as? String)
        let token = source["token"] as? String
        guard let roomString, let roomURL = URL(string: roomString), let token else {
            throw PairingError.missingCredentials
        }
        return PairingCredentials(roomURL: roomURL, token: token)
    }
}
