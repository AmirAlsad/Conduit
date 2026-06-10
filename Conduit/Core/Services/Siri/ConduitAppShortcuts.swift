//
//  ConduitAppShortcuts.swift
//  Conduit
//
//  Registers the "Call <agent> on Conduit" phrases with Siri. Parameterized
//  phrases only work after the system has fetched the agent names, so
//  refreshParameters() runs at launch and after every agent save/delete —
//  vocabulary refresh is not instant (up to ~a minute on device).
//

import AppIntents

struct ConduitAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CallAgentIntent(),
            phrases: [
                "Call \(\.$agent) on \(.applicationName)",
                "Call \(\.$agent) with \(.applicationName)",
                "Call \(\.$agent) using \(.applicationName)",
                "Dial \(\.$agent) on \(.applicationName)",
                "\(.applicationName) call \(\.$agent)",
                "Call my agent on \(.applicationName)",
                "Make a \(.applicationName) call"
            ],
            shortTitle: "Call Agent",
            systemImageName: "phone.fill"
        )
    }

    /// One uniform hook for the agent-set mutation sites (launch, save, delete).
    static func refreshParameters() {
        updateAppShortcutParameters()
    }
}
