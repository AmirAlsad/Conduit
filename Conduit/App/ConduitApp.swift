//
//  ConduitApp.swift
//  Conduit
//
//  App entry point. Conduit is a bring-your-own-agent voice client
//  (CallKit + WebRTC); see voice-agent-callkit-plan.md.
//

import SwiftData
import SwiftUI

@main
struct ConduitApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(environment)
                .modelContainer(environment.modelContainer)
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
