//
//  PairingClient.swift
//  Conduit
//
//  Resolves a bring-your-own pairing endpoint into a fresh room + token for one
//  call: POST the endpoint with the API key as a bearer and `{transport,
//  call_signals}` (plus `ring` when the call is still ringing, see `PairingRing`),
//  then read the credentials. `call_signals` tells the backend that this app sends
//  `call-connected`, so its agent waits for it before greeting. A backend that
//  predates `call_signals` or `ring` ignores them and dispatches as for any call. The endpoint itself identifies the agent (one endpoint
//  per agent), so no agent id is sent. The reference engine nests credentials
//  under `connection` (which is why the SDK's built-in pairing decoder choked); a
//  flat shape is also accepted, and `url` is read as a fallback key because
//  LiveKit token servers commonly name the server URL that way. This talks to the
//  USER's own server — there is no backend of ours.
//

import ConduitCallEngine
import Foundation

enum PairingClient {
    static func resolve(
        endpoint: URL,
        apiKey: String,
        transport: TransportKind,
        ring: PairingRing? = nil,
        session: URLSession = .shared
    ) async throws -> PairingCredentials {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body(transport: transport, ring: ring))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PairingError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw PairingError.unauthorized }
            throw PairingError.server(http.statusCode)
        }
        return try parse(data)
    }

    /// The call-control signals every call of this app carries (all three
    /// transports deliver them), as the backend sees them on the wire. Only
    /// `call-connected`: the engine sends `call-held` and `call-resumed` only with
    /// its experimental hold, which the app leaves off.
    static let callSignals = [CallSignal.connected.rawValue]

    static func body(transport: TransportKind, ring: PairingRing?) -> [String: Any] {
        var body: [String: Any] = ["transport": transport.rawValue, "call_signals": callSignals]
        body["ring"] = ring?.body
        return body
    }

    /// Extract the room URL + token. Accepts the engine's nested
    /// `{ "connection": { "room_url", "token" } }` and a flat
    /// `{ "room_url" | "roomUrl" | "url", "token" }` fallback —
    /// `room_url` is canonical and wins when several are present.
    static func parse(_ data: Data) throws -> PairingCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PairingError.invalidResponse
        }
        let source = (root["connection"] as? [String: Any]) ?? root
        let roomString = (source["room_url"] as? String)
            ?? (source["roomUrl"] as? String)
            ?? (source["url"] as? String)
        let token = source["token"] as? String
        guard let roomString, let roomURL = URL(string: roomString), let token else {
            throw PairingError.missingCredentials
        }
        return PairingCredentials(roomURL: roomURL, token: token)
    }
}
