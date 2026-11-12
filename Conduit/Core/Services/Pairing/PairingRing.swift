//
//  PairingRing.swift
//  Conduit
//
//  The ring a pairing request is made for, when the engine prepares an incoming
//  call while the phone still rings (pre-connect). Sent as the body's `ring`, so
//  the user's backend can dispatch its agent for that ring and, with
//  `awaitAnswer`, keep it silent until the app's `call-answered`.
//

import ConduitCallEngine
import Foundation

struct PairingRing: Equatable, Sendable {
    let callID: UUID
    /// The app joins the room before the user answers (the `.media` tier).
    let awaitAnswer: Bool

    /// The ring a credential request is for: only a request made during a ring
    /// carries one. An answered ring or a reconnect asks as an ordinary pairing
    /// call, because a backend treats a `ring` as a bot with a ring deadline.
    init?(_ request: ConnectRequest) {
        guard case .ringing(let joinsBeforeAnswer) = request.purpose, let callID = request.callID else {
            return nil
        }
        self.init(callID: callID, awaitAnswer: joinsBeforeAnswer)
    }

    init(callID: UUID, awaitAnswer: Bool) {
        self.callID = callID
        self.awaitAnswer = awaitAnswer
    }

    /// The `ring` object of the pairing body. The id is lowercase, the form the
    /// reference backend issues `call_id`s in and looks them up by.
    var body: [String: Any] {
        ["call_id": callID.uuidString.lowercased(), "await_answer": awaitAnswer]
    }
}
