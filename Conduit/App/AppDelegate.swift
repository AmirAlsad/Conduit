//
//  AppDelegate.swift
//  Conduit
//
//  SwiftUI owns the lifecycle; this UIKit adaptor stands up PushKit early in
//  launch (it must be registered before the first VoIP push) for inbound,
//  agent-initiated calls (see `VoIPPushService`), and vends the SiriKit
//  calling-domain handler for in-app intent handling (see `SiriCallHandler`).
//

import Intents
import PushKit
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private var pushService: VoIPPushService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let service = VoIPPushService(environment: .shared)
        service.start()
        pushService = service
        AppEnvironment.shared.inboundRegistrar = service
        return true
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INStartCallIntent ? SiriCallHandler(environment: .shared) : nil
    }
}
