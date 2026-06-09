//
//  AppDelegate.swift
//  Conduit
//
//  SwiftUI owns the lifecycle; this UIKit adaptor exists only to stand up PushKit
//  early in launch (it must be registered before the first VoIP push) for inbound,
//  agent-initiated calls. See `VoIPPushService`.
//

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
        return true
    }
}
