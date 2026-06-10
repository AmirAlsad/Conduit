//
//  VoIPPushService.swift
//  Conduit
//
//  Wraps PushKit. On a VoIP token update it registers the token with every agent
//  that opted into inbound calls (`inboundRegistrationURL`); on an incoming push it
//  parses the payload and hands it to the coordinator, which rings via CallKit.
//
//  Device-only: PushKit doesn't deliver in the simulator. The token-registration
//  POST (`PushTokenRegistrar`) and payload parsing (`IncomingCallPayload`) are the
//  unit-tested pieces; the live push round-trip is verified on hardware.
//
//  NOTE (device): iOS requires `reportNewIncomingCall` to be invoked within the push
//  handler or the app is terminated. `receiveCall` reports synchronously before the
//  completion fires; keep that invariant if this is refactored.
//

import Foundation
import PushKit

@MainActor
final class VoIPPushService: NSObject, PKPushRegistryDelegate {
    private let environment: AppEnvironment
    private var registry: PKPushRegistry?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Create the registry and request the VoIP token. Call once, early in launch.
    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    // MARK: - PKPushRegistryDelegate (delivered on the main queue)

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = Self.hexString(pushCredentials.token)
        MainActor.assumeIsolated {
            _ = Task { await self.registerTokenWithAgents(token) }
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            guard type == .voIP, let parsed = IncomingCallPayload(dictionary: payload.dictionaryPayload) else {
                Log.warning(.callkit, "Dropping VoIP push: unparseable payload")
                completion()
                return
            }
            Task {
                await self.environment.callSession.receiveCall(parsed)
                completion()
            }
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        Log.warning(.callkit, "VoIP push token invalidated")
    }

    // MARK: - Token registration

    private func registerTokenWithAgents(_ token: String) async {
        let agents = ((try? environment.agentRepository.fetchAll()) ?? [])
            .filter { $0.inboundRegistrationURL != nil }
        for agent in agents {
            await register(token: token, agent: agent)
        }
    }

    private func register(token: String, agent: Agent) async {
        guard let endpoint = agent.inboundRegistrationURL else { return }
        let apiKey = (try? environment.keychain.token(
            for: KeychainTokenRef(account: agent.keychainTokenRef)
        )) ?? nil
        await PushTokenRegistrar.register(
            token: token,
            agentID: agent.id,
            endpoint: endpoint,
            apiKey: apiKey ?? ""
        )
    }

    private nonisolated static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - InboundRegistering (registration on toggle-save, not just app launch)

extension VoIPPushService: InboundRegistering {
    func registerInbound(for agent: Agent) async {
        guard let tokenData = registry?.pushToken(for: .voIP), !tokenData.isEmpty else { return }
        await register(token: Self.hexString(tokenData), agent: agent)
    }
}
