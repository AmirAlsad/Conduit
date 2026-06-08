//
//  DebugEngineConnect.swift
//  Conduit
//
//  DEBUG-only client for the Conduit engine's `/connect` pairing contract: POST
//  the bearer + {agent_id, transport}, read the credentials nested under
//  `connection` (this engine nests them, unlike the vanilla Pipecat quickstart),
//  and hand back a room URL + token for a direct transport connect.
//
//  This talks to the USER's own deployed engine (bring-your-own) — not a backend
//  of ours. The production pairing client (formalizing this as the published
//  connection spec) lands with the add-agent flow; this is the M2 verification path.
//

#if DEBUG
import Foundation

enum DebugEngineConnect {
    struct DailyCreds {
        let roomURL: URL
        let token: String
    }

    struct EngineError: Error, CustomStringConvertible {
        let description: String
    }

    /// POST `{base}/connect` and return the Daily room credentials.
    static func fetchDaily(baseURL: URL, apiKey: String, agentID: String) async throws -> DailyCreds {
        var request = URLRequest(url: baseURL.appendingPathComponent("connect"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["agent_id": agentID, "transport": "daily"]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError(description: "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EngineError(description: "HTTP \(http.statusCode): \(body)")
        }

        let decoded = try JSONDecoder().decode(ConnectResponse.self, from: data)
        guard let roomString = decoded.connection.room_url,
              let roomURL = URL(string: roomString),
              let token = decoded.connection.token else {
            throw EngineError(description: "Missing connection.room_url/token in response")
        }
        return DailyCreds(roomURL: roomURL, token: token)
    }

    private struct ConnectResponse: Decodable {
        let connection: Connection
        struct Connection: Decodable {
            let room_url: String?
            let token: String?
        }
    }
}
#endif
