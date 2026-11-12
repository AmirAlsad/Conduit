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
                Text("When on, the mic opens only while you hold the talk button. [Learn more.](\(ExternalLinks.pushToTalkDocs.absoluteString))")
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Text("Your agent, your keys — credentials never leave this device. [Learn more.](\(ExternalLinks.usingConduit.absoluteString)#privacy)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Settings.aboutRow)
                Link("Tap to learn how to connect your agent.", destination: ExternalLinks.connectYourAgent)
                    .accessibilityIdentifier(AccessibilityID.Settings.agentSetupLink)
            }

        }
        .navigationTitle("Settings")
        .brandMarkToolbar()
        .accessibilityIdentifier(AccessibilityID.Settings.screen)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(AppEnvironment.inMemory())
}
