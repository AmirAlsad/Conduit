//
//  ConduitApp.swift
//  Conduit
//
//  App entry point. Conduit is a bring-your-own-agent voice client
//  (CallKit + WebRTC); see docs/ARCHITECTURE.md.
//

import Intents
import SwiftData
import SwiftUI

@main
struct ConduitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(environment)
                .modelContainer(environment.modelContainer)
                .onOpenURL { url in
                    // The link may carry an API key — never log the URL itself.
                    do {
                        let link = try DeepLinkParser.parse(url)
                        Log.info(.app, "Deep link parsed (hasKey: \(link.apiKey != nil))")
                        environment.pendingAgentLink = link
                    } catch {
                        Log.warning(.app, "Ignoring deep link: \(error)")
                    }
                }
                // SiriKit "call <agent>" lands here after SiriCallHandler
                // responds .continueInApp; same funnel as the App Intent.
                .onContinueUserActivity(NSStringFromClass(INStartCallIntent.self)) { activity in
                    guard let intent = activity.interaction?.intent as? INStartCallIntent,
                          let idString = intent.contacts?.first?.customIdentifier,
                          let id = UUID(uuidString: idString) else {
                        Log.warning(.call, "SiriKit activity missing agent identifier")
                        return
                    }
                    Log.info(.call, "SiriKit dial continued in app")
                    environment.pendingSiriCall = id
                }
                // Parameterized Siri phrases only resolve after the system has
                // fetched the agent names; refresh at launch and on every
                // agent mutation (save/delete hooks).
                .task { ConduitAppShortcuts.refreshParameters() }
                // Without this one-time prompt, Settings' "Use with Siri
                // Requests" toggle defaults OFF and Siri claims the app has no
                // support (found in the M10 device pass).
                .task {
                    if INPreferences.siriAuthorizationStatus() == .notDetermined {
                        INPreferences.requestSiriAuthorization { status in
                            Log.info(.app, "Siri authorization: \(String(describing: status))")
                        }
                    }
                }
                #if DEBUG
                .task {
                    DebugSeed.runIfRequested(environment)
                    if ProcessInfo.processInfo.environment["CONDUIT_DEBUG_CALLKIT"] == "1" {
                        await DebugCallKitSpike.runIfRequested()
                    } else {
                        await DebugDailyAutoConnect.runIfRequested()
                    }
                }
                #endif
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        // CONDUIT_DEBUG_INCALL=1 boots straight into the in-call surface (idle
        // coordinator) so its look can be screenshotted in the simulator without
        // placing a real call.
        if ProcessInfo.processInfo.environment["CONDUIT_DEBUG_INCALL"] == "1" {
            InCallView()
        } else {
            RootTabView()
        }
        #else
        RootTabView()
        #endif
    }
}
