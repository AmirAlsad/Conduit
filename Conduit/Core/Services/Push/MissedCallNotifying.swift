//
//  MissedCallNotifying.swift
//  Conduit
//
//  Posts a local "missed call" notification for every inbound ring nobody answered
//  or declined: one that rang out or that the caller withdrew, a Focus/DND-filtered
//  ring, and a push that arrived mid-call. The system only posts missed-call
//  notifications for the built-in Phone app — CallKit apps post their own. Uses provisional authorization, so notifications deliver quietly to
//  Notification Center without ever showing a permission prompt.
//

import ConduitCallEngine
import Foundation
import UserNotifications

@MainActor
protocol MissedCallNotifying: AnyObject {
    func notifyMissedCall(agentName: String, reason: MissedCallReason)
}

@MainActor
final class MissedCallNotifier: MissedCallNotifying {
    func notifyMissedCall(agentName: String, reason: MissedCallReason) {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
            let content = UNMutableNotificationContent()
            content.title = "Missed Call"
            content.body = reason.notificationBody(agentName: agentName)
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
            do { try await center.add(request) }
            catch { Log.error(.call, "Missed-call notification failed: \(error)") }
        }
    }
}

@MainActor
final class FakeMissedCallNotifier: MissedCallNotifying {
    private(set) var missedAgentNames: [String] = []
    private(set) var missedReasons: [MissedCallReason] = []

    func notifyMissedCall(agentName: String, reason: MissedCallReason) {
        missedAgentNames.append(agentName)
        missedReasons.append(reason)
    }
}
