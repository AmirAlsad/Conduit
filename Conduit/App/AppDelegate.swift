//
//  AppDelegate.swift
//  Conduit
//
//  SwiftUI owns the lifecycle; this UIKit adaptor starts the call engine's
//  PushKit registration early in launch (it must be registered before the first
//  VoIP push) for inbound, agent-initiated calls, vends the SiriKit
//  calling-domain handler for in-app intent handling (see `SiriCallHandler`), and
//  lets missed-call notices reach Notification Center while the app is in front.
//

import ConduitCallEngine
import Intents
import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let environment = AppEnvironment.shared
        environment.callEngine.startPushRegistration()
        environment.inboundRegistrar = environment.callHost
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Without a delegate, iOS drops a notification delivered while the app is in
    // the foreground, which is exactly when a ring arrives during a call. List it
    // quietly (no banner or sound), the same way a background delivery lands.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.list]
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INStartCallIntent ? SiriCallHandler(environment: .shared) : nil
    }
}
