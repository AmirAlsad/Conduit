//
//  IncomingCallPayload.swift
//  Conduit
//
//  The parsed contents of an agent's VoIP push: which agent is calling, the call's
//  id, and OPTIONAL inline room credentials. Hybrid resolution — if `room_url` +
//  `token` are present the app joins directly; otherwise it resolves the agent's
//  pairing endpoint after the user answers (so credentials needn't ride the push).
//  See `docs/INBOUND_CALLS.md` for the server contract.
//

import Foundation

struct IncomingCallPayload: Equatable, Sendable {
    let agentID: UUID
    let callID: UUID
    let roomURL: URL?
    let token: String?
    /// Where to POST the ring's terminal status (answered/declined/busy/
    /// suppressed_by_focus), when the server asked for receipts. Optional —
    /// servers that don't care simply omit it.
    let statusURL: URL?

    /// Inline credentials, if the push carried both a room and a token.
    var inlineCredentials: PairingCredentials? {
        guard let roomURL, let token, !token.isEmpty else { return nil }
        return PairingCredentials(roomURL: roomURL, token: token)
    }
}

extension IncomingCallPayload {
    /// Parse the PushKit payload dictionary. `agent_id` (a UUID) is required;
    /// `call_id` becomes the CallKit UUID (a fresh one is minted if absent). Inline
    /// `room_url` + `token` are optional.
    init?(dictionary: [AnyHashable: Any]) {
        guard
            let agentString = dictionary["agent_id"] as? String,
            let agentID = UUID(uuidString: agentString)
        else { return nil }
        self.agentID = agentID
        self.callID = (dictionary["call_id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        self.roomURL = (dictionary["room_url"] as? String).flatMap { URL(string: $0) }
        self.token = dictionary["token"] as? String
        self.statusURL = (dictionary["status_url"] as? String).flatMap { URL(string: $0) }
    }
}
