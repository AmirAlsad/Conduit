//
//  CallInteractionDonor.swift
//  Conduit
//
//  Donates an INStartCallIntent interaction after each placed call — this is
//  what teaches Siri's calling domain that calls to this contact happen through
//  Conduit, so the bare "Hey Siri, call <agent>" (no app name) offers/uses the
//  app. The mirror contact carries only the synthetic email (deliberately no
//  phone number — a number would make Siri dial it via the Phone app), so
//  without donations Siri sees the contact as uncallable.
//

import Foundation
import Intents

protocol CallInteractionDonating {
    func donateOutgoingCall(to agent: Agent)
}

struct CallInteractionDonor: CallInteractionDonating {
    func donateOutgoingCall(to agent: Agent) {
        let intent = INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: nil,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [SiriCallHandler.person(for: agent)],
            callCapability: .audioCall
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.donate { error in
            if let error {
                Log.warning(.call, "Siri interaction donation failed: \(error)")
            }
        }
    }
}

final class FakeCallInteractionDonor: CallInteractionDonating {
    private(set) var donatedAgentIDs: [UUID] = []

    func donateOutgoingCall(to agent: Agent) {
        donatedAgentIDs.append(agent.id)
    }
}
