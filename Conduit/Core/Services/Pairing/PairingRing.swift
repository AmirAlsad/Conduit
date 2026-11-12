//
//  PairingRing.swift
//  Conduit
//
//  The ring a pairing request is made for, when the engine prepares an incoming
//  call while the phone still rings (pre-connect). Sent as the body's `ring`, so
//  the user's backend can dispatch its agent for that ring, with a ring deadline,
//  and, with `joinsBeforeAnswer`, know that the device's joining is not the answer.
//

import ConduitCallEngine
import Foundation

struct PairingRing: Equatable, Sendable {
    let callID: UUID
    /// The app joins the room before the user answers (the `.media` tier).
    let joinsBeforeAnswer: Bool

    /// The ring a credential request is for: only a request made during a ring
    /// carries one. An answered ring or a reconnect asks as an ordinary pairing
    /// call, because a backend treats a `ring` as a bot with a ring deadline.
    init?(_ request: ConnectRequest) {
        guard case .ringing(let joinsBeforeAnswer) = request.purpose, let callID = request.callID else {
            return nil
        }
        self.init(callID: callID, joinsBeforeAnswer: joinsBeforeAnswer)
    }

    init(callID: UUID, joinsBeforeAnswer: Bool) {
        self.callID = callID
        self.joinsBeforeAnswer = joinsBeforeAnswer
    }

    /// The `ring` object of the pairing body. The id is lowercase, the form the
    /// reference backend issues `call_id`s in and looks them up by.
    var body: [String: Any] {
        ["call_id": callID.uuidString.lowercased(), "joins_before_answer": joinsBeforeAnswer]
    }
}
