//
//  MissedCallDisplayTests.swift
//  ConduitTests
//
//  How a missed ring reads in the call log and in its notification: a ring that
//  rang and went unanswered is a plain missed call, as in the Phone app; one the
//  user never heard says why. Rows without a missed reason keep their outcome copy.
//

import Testing
@testable import Conduit
import ConduitCallEngine

@MainActor
struct MissedCallDisplayTests {

    private func incoming(_ outcome: CallOutcome, missed: MissedCallReason? = nil) -> CallLogEntry {
        CallLogEntry(direction: .incoming, outcome: outcome, transportKind: .livekit, missedReason: missed)
    }

    @Test(arguments: [
        (MissedCallReason.ringTimedOut, "Missed"),
        (.canceledByCaller, "Missed"),
        (.busy, "Missed — on another call"),
        (.filteredByFocus, "Missed — Focus"),
    ])
    func missedRowsReadAsMissed(reason: MissedCallReason, label: String) {
        let entry = incoming(.noAnswer, missed: reason)
        #expect(entry.isMissed)
        #expect(entry.outcomeDisplayLabel == label)
        #expect(entry.iconName == "phone.arrow.down.left")
        #expect(entry.tint == .red)
    }

    @Test func rowsWithoutAMissedReasonKeepTheirOutcome() {
        let noAnswer = incoming(.noAnswer) // the agent left before connecting, or a row from an older build
        #expect(!noAnswer.isMissed)
        #expect(noAnswer.outcomeDisplayLabel == "No answer")
        #expect(noAnswer.iconName == "phone.arrow.down.left")

        let failed = CallLogEntry(outcome: .failed, transportKind: .daily, failureReason: .badToken)
        #expect(failed.outcomeDisplayLabel == "Failed — authentication")
        #expect(failed.tint == .red)
    }

    @Test(arguments: [
        (CallDirection.outgoing, CallOutcome.completed, "phone.arrow.up.right"),
        (.incoming, .completed, "phone.arrow.down.left"),
        (.outgoing, .canceled, "phone.arrow.up.right"),
        (.incoming, .canceled, "phone.arrow.down.left"),
        (.outgoing, .failed, "phone.down.fill"),
        (.incoming, .declined, "phone.down.fill"),
    ])
    func theRowsArrowFollowsTheCallsDirection(direction: CallDirection, outcome: CallOutcome, icon: String) {
        let entry = CallLogEntry(direction: direction, outcome: outcome, transportKind: .daily)
        #expect(entry.iconName == icon)
    }

    @Test func missedReasonSurvivesItsRawValue() {
        for reason in [MissedCallReason.busy, .filteredByFocus, .ringTimedOut, .canceledByCaller] {
            #expect(incoming(.noAnswer, missed: reason).missedReason == reason)
        }
    }

    @Test(arguments: [
        (MissedCallReason.ringTimedOut, "Nova tried to call you."),
        (.canceledByCaller, "Nova tried to call you."),
        (.busy, "Nova tried to call you during another call."),
        (.filteredByFocus, "Nova tried to call you while Focus was on."),
    ])
    func notificationBodySaysWhyWhenTheRingNeverRang(reason: MissedCallReason, body: String) {
        #expect(reason.notificationBody(agentName: "Nova") == body)
    }
}
