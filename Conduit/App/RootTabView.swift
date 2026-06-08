//
//  RootTabView.swift
//  Conduit
//
//  The app's three-tab shell, modeled on the Phone app: Recents (home),
//  Contacts, Settings. Tab contents are placeholders until their feature modules
//  land (WS-5); the in-call surface will present over this as a full-screen cover.
//

import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Recents", systemImage: "clock") {
                NavigationStack {
                    ContentUnavailableView(
                        "No Recent Calls",
                        systemImage: "clock",
                        description: Text("Calls to your agents will appear here.")
                    )
                    .navigationTitle("Recents")
                    .accessibilityIdentifier(AccessibilityID.Root.tab(0))
                }
            }

            Tab("Contacts", systemImage: "person.crop.circle") {
                NavigationStack {
                    ContentUnavailableView(
                        "No Agents",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Add an agent to start calling.")
                    )
                    .navigationTitle("Contacts")
                    .accessibilityIdentifier(AccessibilityID.Root.tab(1))
                }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    Group {
                        #if DEBUG
                        List {
                            Section("Developer") {
                                NavigationLink {
                                    DebugDailyConnectView()
                                } label: {
                                    Label("Daily connect (debug)", systemImage: "ladybug")
                                }
                                .accessibilityIdentifier(AccessibilityID.Debug.dailyConnectLink)
                            }
                        }
                        #else
                        ContentUnavailableView(
                            "Settings",
                            systemImage: "gearshape",
                            description: Text("Always-listening, push-to-talk, and About.")
                        )
                        #endif
                    }
                    .navigationTitle("Settings")
                    .accessibilityIdentifier(AccessibilityID.Root.tab(2))
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Root.screen)
    }
}

#Preview {
    RootTabView()
        .environment(AppEnvironment.inMemory())
}
