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
    @State private var environment = AppEnvironment.inMemory()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(environment)
                .modelContainer(environment.modelContainer)
                #if DEBUG
                .task { await DebugDailyAutoConnect.runIfRequested() }
                #endif
        }
    }
}
