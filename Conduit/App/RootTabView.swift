//
//  RootTabView.swift
//  Conduit
//
//  The app's three-tab shell, modeled on the Phone app: Recents (home), Contacts,
//  Settings. The in-call surface presents over the whole shell as a full-screen
//  cover whenever a call is active (`callSession.state.isActive`).
//

import SwiftUI

struct RootTabView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        TabView {
            Tab("Recents", systemImage: "clock") {
                NavigationStack { RecentsView() }
            }

            Tab("Contacts", systemImage: "person.crop.circle") {
                NavigationStack { ContactsView() }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Root.screen)
        .fullScreenCover(isPresented: callActive) {
            InCallView()
                .environment(environment)
        }
    }

    /// Drives the in-call cover from the coordinator. Programmatic dismissal calls
    /// `reset()`, which only takes effect once the call is terminal — so an active
    /// call can never be swiped/dismissed away.
    private var callActive: Binding<Bool> {
        Binding(
            get: { environment.callSession.state.isActive },
            set: { active in if !active { environment.callSession.reset() } }
        )
    }
}

#Preview {
    RootTabView()
        .environment(AppEnvironment.inMemory())
}
