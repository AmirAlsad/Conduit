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
    @Environment(\.scenePhase) private var scenePhase

    private enum RootTab: Hashable {
        case recents, contacts, settings
    }

    @State private var selection: RootTab = .recents

    var body: some View {
        TabView(selection: $selection) {
            Tab("Recents", systemImage: "clock", value: RootTab.recents) {
                NavigationStack { RecentsView() }
            }

            Tab("Contacts", systemImage: "person.crop.circle", value: RootTab.contacts) {
                NavigationStack { ContactsView() }
            }

            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                NavigationStack { SettingsView() }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Root.screen)
        .fullScreenCover(isPresented: callActive) {
            InCallView()
                .environment(environment)
        }
        // A conduit:// add-agent link lands on the Contacts tab, whose view
        // owns presenting the (pre-filled) sheet.
        .onChange(of: environment.pendingAgentLink) { _, link in
            if link != nil { selection = .contacts }
        }
        // A Siri-requested call dials only once the scene is .active —
        // CXStartCallAction from a not-yet-foregrounded app is rejected.
        .onChange(of: environment.pendingSiriCall) { _, _ in consumePendingSiriCall() }
        .onChange(of: scenePhase) { _, _ in consumePendingSiriCall() }
        .onAppear {
            if environment.pendingAgentLink != nil { selection = .contacts }
            consumePendingSiriCall()
        }
    }

    private func consumePendingSiriCall() {
        guard scenePhase == .active, let pending = environment.pendingSiriCall else { return }
        environment.pendingSiriCall = nil
        guard !pending.isExpired else {
            Log.info(.call, "Siri dial dropped — request expired unconsumed")
            return
        }
        guard !environment.callSession.state.isActive else {
            Log.info(.call, "Siri dial dropped — a call is already active")
            return
        }
        guard let agent = try? environment.agentRepository.fetch(id: pending.agentID) else {
            Log.warning(.call, "Siri dial dropped — unknown agent id")
            return
        }
        Log.info(.call, "Siri dial: placing call")
        Task { await environment.callSession.placeCall(agent) }
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
