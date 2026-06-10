//
//  MissedCallNotifying.swift
//  Conduit
//
//  Posts a local "missed call" notification for inbound rings the user never saw
//  ring: Focus/DND-filtered calls and pushes that arrived mid-call. The system only
//  posts missed-call notifications for the built-in Phone app — CallKit apps post
//  their own. Uses provisional authorization, so notifications deliver quietly to
//  Notification Center without ever showing a permission prompt.
//

import Foundation
import UserNotifications

@MainActor
protocol MissedCallNotifying: AnyObject {
    func notifyMissedCall(agentName: String)
}

@MainActor
final class MissedCallNotifier: MissedCallNotifying {
    func notifyMissedCall(agentName: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
            let content = UNMutableNotificationContent()
            content.title = "Missed Call"
            content.body = "\(agentName) tried to call you."
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

    func notifyMissedCall(agentName: String) {
        missedAgentNames.append(agentName)
    }
}
