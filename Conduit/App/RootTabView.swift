//
//  RootTabView.swift
//  Conduit
//
//  The app's three-tab shell, modeled on the Phone app: Recents (home), Contacts,
//  Settings. The in-call surface presents over the whole shell as a full-screen
//  overlay whenever a call is active (`callSession.state.isActive`) and not
//  minimized — an app-owned overlay (not a modal cover) so its dismiss transition
//  is ours to control (a user-end vanishes instantly; see `syncInCallCover`).
//

import SwiftUI

struct RootTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    private enum RootTab: Hashable {
        case recents, contacts, settings
    }

    @State private var selection: RootTab = Self.initialTab

    /// DEBUG: boot straight to a chosen tab (CONDUIT_DEBUG_TAB=contacts|settings) so
    /// each tab can be screenshotted in the simulator without an accessibility tap —
    /// iOS 26's simulator reports a 0x0 frame, which breaks tap-by-identifier.
    private static var initialTab: RootTab {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["CONDUIT_DEBUG_TAB"] {
        case "contacts": return .contacts
        case "settings": return .settings
        default: return .recents
        }
        #else
        return .recents
        #endif
    }
    /// Whether the in-call overlay is shown. Owned here (not a computed Binding) so
    /// `syncInCallCover` can flip it with the right transaction — animated for
    /// present/minimize/Close, instant for a user-end (no flash).
    @State private var inCallPresented = false

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                Tab("Recents", systemImage: "clock", value: RootTab.recents) {
                    NavigationStack { RecentsView().returnToCallToolbar() }
                }

                Tab("Contacts", systemImage: "person.crop.circle", value: RootTab.contacts) {
                    NavigationStack { ContactsView().returnToCallToolbar() }
                }

                Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                    NavigationStack { SettingsView().returnToCallToolbar() }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Root.screen)

            // The in-call surface is an app-owned overlay, not a `fullScreenCover`, so
            // we control its transition: a user-end removes it INSTANTLY (no slide-down
            // flash — a modal cover always animates its own teardown), while present,
            // minimize, and the remote-end / failure Close animate (see syncInCallCover).
            if inCallPresented {
                InCallView()
                    .environment(environment)
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .onChange(of: callShouldPresent) { _, present in syncInCallCover(present) }
        // A conduit:// add-agent link lands on the Contacts tab, whose view
        // owns presenting the (pre-filled) sheet.
        .onChange(of: environment.pendingAgentLink) { _, link in
            if link != nil { selection = .contacts }
        }
        // A Siri-requested call dials only once the scene is .active —
        // CXStartCallAction from a not-yet-foregrounded app is rejected.
        .onChange(of: environment.pendingSiriCall) { _, _ in consumePendingSiriCall() }
        .onChange(of: scenePhase) { old, new in
            consumePendingSiriCall()
            // Returning to the foreground (e.g. tapping the CallKit Dynamic Island /
            // status-bar pill) re-presents a minimized, still-active call.
            if new == .active, old != .active,
               environment.callSession.state.isActive,
               environment.isCallScreenMinimized {
                environment.isCallScreenMinimized = false
            }
        }
        // Reset to idle (dismissing the cover) when the user ended the call — so no
        // "Call Ended" page shows — or when a call ends while minimized (no in-call
        // view is up to do it). A remote hangup or failure on the presented screen is
        // left terminal so its page stays until the user taps Close.
        .onChange(of: environment.callSession.state.isTerminal) { _, isTerminal in
            guard isTerminal else { return }
            if environment.callSession.endedByUser || environment.isCallScreenMinimized {
                environment.callSession.reset()
                environment.isCallScreenMinimized = false
            }
        }
        .onAppear {
            if environment.pendingAgentLink != nil { selection = .contacts }
            inCallPresented = callShouldPresent
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

    /// Whether the in-call cover should be shown: an active call the user hasn't
    /// minimized or just ended.
    private var callShouldPresent: Bool {
        environment.callSession.state.isActive
            && !environment.isCallScreenMinimized
            && !environment.callSession.endedByUser
    }

    /// Drive the in-call overlay's `@State` to match. Present and minimize animate;
    /// ending or closing a call dismisses INSTANTLY (no transition → no flash).
    /// Dismissal is entirely state-driven, so it never ends the call.
    private func syncInCallCover(_ present: Bool) {
        if present {
            withAnimation(.snappy) { inCallPresented = true }
        } else if environment.isCallScreenMinimized {
            // Minimize is a deliberate gesture — let it slide down.
            withAnimation(.snappy) { inCallPresented = false }
        } else {
            // Ending or closing a call (End button, or Close on a failed/ended
            // screen) dismisses instantly — no transition, no flash.
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) { inCallPresented = false }
        }
    }
}

#Preview {
    RootTabView()
        .environment(AppEnvironment.inMemory())
}
