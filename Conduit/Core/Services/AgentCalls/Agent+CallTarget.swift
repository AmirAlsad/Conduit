//
//  Agent+CallTarget.swift
//  Conduit
//
//  How an agent becomes something the call engine can dial: its identity for
//  CallKit, the transport its kind selects, how much of a ring the engine may
//  prepare before the answer, and the credential step the engine runs before
//  every connect attempt — inline push credentials as-is, otherwise the agent's
//  pairing endpoint (re-paired on every attempt, told which ring a request made
//  while ringing is for) or its direct room. The agent's configuration and
//  Keychain secret are captured once, so every attempt resolves against the same
//  values. Failures surface as `TransportError`s, which the engine maps to a
//  failure reason.
//

import ConduitCallEngine
import Foundation

typealias PairingResolving = @Sendable (URL, String, TransportKind, PairingRing?) async throws -> PairingCredentials

extension Agent {
    static let livePairingResolver: PairingResolving = {
        try await PairingClient.resolve(endpoint: $0, apiKey: $1, transport: $2, ring: $3)
    }

    /// `ringPreparation` is the most of an incoming ring the engine may prepare
    /// before the answer (the push must ask for it too); outgoing calls ignore it.
    func callTarget(
        keychain: KeychainStoring,
        transportFactory: @escaping (TransportKind) -> CallTransport,
        pairingResolver: @escaping PairingResolving = Agent.livePairingResolver,
        inlineConnection: CallConnection? = nil,
        ringPreparation: RingPreparation = .none
    ) -> CallTarget {
        let kind = transportKind
        return CallTarget(
            id: id,
            displayName: name,
            handle: syntheticEmail,
            makeTransport: { transportFactory(kind) },
            connect: connectionResolver(
                keychain: keychain,
                pairingResolver: pairingResolver,
                inlineConnection: inlineConnection
            ),
            ringPreparation: ringPreparation
        )
    }

    private func connectionResolver(
        keychain: KeychainStoring,
        pairingResolver: @escaping PairingResolving,
        inlineConnection: CallConnection?
    ) -> @MainActor (ConnectRequest) async throws -> CallConnection {
        if let inlineConnection {
            return { _ in inlineConnection }
        }

        let token = callToken(keychain: keychain) ?? ""
        if let endpoint = pairingEndpoint {
            let kind = transportKind
            return { request in
                do {
                    let creds = try await pairingResolver(endpoint, token, kind, PairingRing(request))
                    return CallConnection(url: creds.roomURL, token: creds.token)
                } catch let error as PairingError {
                    Log.error(.transport, "Pairing failed: \(error)")
                    throw error == .unauthorized ? TransportError.authenticationFailed
                                                 : TransportError.connectionFailed("pairing: \(error)")
                } catch {
                    throw TransportError.connectionFailed(String(describing: error))
                }
            }
        }

        let url = connectionURL
        let email = syntheticEmail
        return { _ in
            // Direct mode needs its room token; pairing mode authenticates with its API
            // key, but an endpoint may be open, so it doesn't hard-require one.
            guard !token.isEmpty else {
                Log.error(.call, "No token for agent \(Log.redactEmail(email))")
                throw TransportError.authenticationFailed
            }
            guard let url else { throw TransportError.connectionFailed("No room URL or pairing endpoint") }
            return CallConnection(url: url, token: token)
        }
    }

    /// The secret for the path a call will take: the pairing API key when a
    /// pairing endpoint is set (it wins if both are configured), otherwise the
    /// direct-room token. Each lives under its own Keychain ref.
    private func callToken(keychain: KeychainStoring) -> String? {
        let ref = pairingEndpoint != nil
            ? KeychainTokenRef(account: keychainTokenRef)
            : KeychainTokenRef(directTokenForAgentID: id)
        let token = try? keychain.token(for: ref)
        guard let token, !token.isEmpty else { return nil }
        return token
    }
}
