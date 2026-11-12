//
//  PushTokenRegistrar.swift
//  Conduit
//
//  POSTs this device's VoIP push token to an agent's own inbound-registration
//  endpoint (bearer = the agent's API key), so that server can later ring the user.
//  The token only ever travels to the user's own servers — there is no backend of
//  ours. It travels with the push features this build's engine understands, so the
//  server sends a cancel push or a `ring_timeout` only to an app that handles them,
//  and the call-control signals its calls carry, so an agent the server starts for a
//  ring waits for `call-connected` before it greets.
//  See `docs/INBOUND_CALLS.md` for the contract.
//

import ConduitCallEngine
import Foundation

enum PushTokenRegistrar {
    /// The longest caller name sent, in Unicode scalars. The reference backend
    /// rejects the whole registration when `display_name` exceeds 128 code points;
    /// a shortened name is corrected to the full one when the engine resolves the ring.
    static let maxDisplayNameLength = 120

    static func register(
        token: String,
        agentID: UUID,
        displayName: String,
        handle: String,
        endpoint: URL,
        apiKey: String,
        bundleID: String = Bundle.main.bundleIdentifier ?? "",
        pushFeatures: [String] = CallEngine.supportedPushFeatures.sorted(),
        callSignals: [String] = PairingClient.callSignals,
        session: URLSession = .shared
    ) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "voip_token": token,
            "platform": "ios",
            "bundle_id": bundleID,
            "agent_id": agentID.uuidString,
            "display_name": String(String.UnicodeScalarView(displayName.unicodeScalars.prefix(maxDisplayNameLength))),
            "handle": handle,
            "push_features": pushFeatures,
            "call_signals": callSignals,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await session.data(for: request)
            if let failure = httpFailure(response) {
                Log.warning(.network, "VoIP token registration failed: \(failure)")
            } else {
                Log.info(.network, "Registered VoIP token with agent endpoint")
            }
        } catch {
            Log.warning(.network, "VoIP token registration failed: \(error)")
        }
    }

    /// Best-effort unregistration when the user deletes an inbound-enabled agent:
    /// DELETE on the same registration endpoint, so a well-behaved server stops
    /// ringing immediately. Deletion is NOT revocation — a server that ignores
    /// this keeps a working token until the app is reinstalled (token rotation).
    /// See `docs/INBOUND_CALLS.md`.
    static func unregister(
        endpoint: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await session.data(for: request)
            if let failure = httpFailure(response) {
                Log.warning(.network, "VoIP token unregistration failed: \(failure)")
            } else {
                Log.info(.network, "Unregistered VoIP token with agent endpoint")
            }
        } catch {
            Log.warning(.network, "VoIP token unregistration failed: \(error)")
        }
    }

    /// A description of a non-2xx response, or nil when the server accepted it.
    private static func httpFailure(_ response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return nil }
        return "HTTP \(http.statusCode)"
    }
}
