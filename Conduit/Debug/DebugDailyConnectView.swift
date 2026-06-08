//
//  DebugDailyConnectView.swift
//  Conduit
//
//  DEBUG-only screen to exercise the real Daily transport without CallKit. Enter
//  the engine base URL + API key, pick an agent, Connect, and watch the live
//  TransportEvent stream; the agent greets on connect and inbound audio plays
//  through the simulator. Credentials are entered at runtime, never committed.
//

#if DEBUG
import SwiftUI

struct DebugDailyConnectView: View {
    @State private var model = DebugDailyConnectModel()

    var body: some View {
        Form {
            Section("Engine") {
                TextField("Base URL", text: $model.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(AccessibilityID.Debug.baseURLField)
                SecureField("API key (Bearer)", text: $model.apiKey)
                    .accessibilityIdentifier(AccessibilityID.Debug.apiKeyField)
                Picker("Agent", selection: $model.agentID) {
                    Text("live").tag("live")
                    Text("loopback").tag("loopback")
                }
                .accessibilityIdentifier(AccessibilityID.Debug.agentPicker)
            }

            Section {
                Button("Connect") { model.connect() }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier(AccessibilityID.Debug.connectButton)
                Button("Disconnect", role: .destructive) { model.disconnect() }
                    .accessibilityIdentifier(AccessibilityID.Debug.disconnectButton)
            }

            Section("State") {
                Text(model.stateText)
                    .font(.headline)
                    .accessibilityIdentifier(AccessibilityID.Debug.stateLabel)
            }

            Section("Event log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .navigationTitle("Engine connect (debug)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
