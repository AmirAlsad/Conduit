//
//  AppDelegate.swift
//  Conduit
//
//  SwiftUI owns the lifecycle; this UIKit adaptor starts the call engine's
//  PushKit registration early in launch (it must be registered before the first
//  VoIP push) for inbound, agent-initiated calls, and vends the SiriKit
//  calling-domain handler for in-app intent handling (see `SiriCallHandler`).
//

import ConduitCallEngine
import Intents
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let environment = AppEnvironment.shared
        environment.callEngine.startPushRegistration()
        environment.inboundRegistrar = environment.callHost
        return true
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INStartCallIntent ? SiriCallHandler(environment: .shared) : nil
    }
}
