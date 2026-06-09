//
//  PushTokenRegistrar.swift
//  Conduit
//
//  POSTs this device's VoIP push token to an agent's own inbound-registration
//  endpoint (bearer = the agent's API key), so that server can later ring the user.
//  The token only ever travels to the user's own servers — there is no backend of
//  ours. See `docs/INBOUND_CALLS.md` for the contract.
//

import Foundation

enum PushTokenRegistrar {
    static func register(
        token: String,
        agentID: UUID,
        endpoint: URL,
        apiKey: String,
        bundleID: String = Bundle.main.bundleIdentifier ?? "",
        session: URLSession = .shared
    ) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: String] = [
            "voip_token": token,
            "platform": "ios",
            "bundle_id": bundleID,
            "agent_id": agentID.uuidString,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            _ = try await session.data(for: request)
            Log.info(.network, "Registered VoIP token with agent endpoint")
        } catch {
            Log.warning(.network, "VoIP token registration failed: \(error)")
        }
    }
}
