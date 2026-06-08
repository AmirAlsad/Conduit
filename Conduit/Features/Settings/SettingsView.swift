//
//  SettingsView.swift
//  Conduit
//
//  The Settings tab's root content: the push-to-talk preference and an About
//  section. Placed inside a NavigationStack by the coordinator, so it owns the
//  title but not the stack itself.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsStore.pushToTalkKey) private var pushToTalk = false

    var body: some View {
        Form {
            Section {
                Toggle("Push to talk", isOn: $pushToTalk)
                    .accessibilityIdentifier(AccessibilityID.Settings.pushToTalkToggle)
            } header: {
                Text("Audio")
            } footer: {
                Text("When on, the mic opens only while you hold the talk button during a call. When off, the agent is always listening.")
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Text("Conduit is a thin, private pipe to your own voice agent. There's no Conduit server — your connection credentials live only in your device Keychain and are never uploaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Settings.aboutRow)
            }

            #if DEBUG
            Section("Developer") {
                NavigationLink {
                    DebugDailyConnectView()
                } label: {
                    Label("Daily connect (debug)", systemImage: "ladybug")
                }
                .accessibilityIdentifier(AccessibilityID.Debug.dailyConnectLink)
            }
            #endif
        }
        .navigationTitle("Settings")
        .brandMarkToolbar()
        .accessibilityIdentifier(AccessibilityID.Settings.screen)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "—" }
        if let build = info?["CFBundleVersion"] as? String {
            return "\(short) (\(build))"
        }
        return short
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(AppEnvironment.inMemory())
}
