//
//  InboundRegistering.swift
//  Conduit
//
//  Re-registers the device's VoIP push token for one agent on demand — so enabling
//  "Let this agent call me" takes effect at save, not at the next app launch.
//  `VoIPPushService` is the real implementation (it holds the PushKit registry the
//  cached token lives in); a no-op when no token has been issued yet, since the
//  launch-time registration pass covers that case once PushKit delivers one.
//

import Foundation

@MainActor
protocol InboundRegistering: AnyObject {
    func registerInbound(for agent: Agent) async
}

@MainActor
final class FakeInboundRegistrar: InboundRegistering {
    private(set) var registeredAgentIDs: [UUID] = []

    func registerInbound(for agent: Agent) async {
        registeredAgentIDs.append(agent.id)
    }
}
