//
//  AddEditAgentSheet.swift
//  Conduit
//
//  The bring-your-own-agent form, presented modally for both adding a new agent
//  and editing an existing one. A thin projection over `AddEditAgentViewModel`;
//  all validation, persistence, and test-connection logic lives there.
//

import SwiftUI

struct AddEditAgentSheet: View {
    @State private var viewModel: AddEditAgentViewModel
    @Environment(\.dismiss) private var dismiss

    init(editing: Agent? = nil, environment: AppEnvironment) {
        _viewModel = State(
            initialValue: AddEditAgentViewModel(
                editing: editing,
                repository: environment.agentRepository,
                keychain: environment.keychain,
                transportFactory: environment.transportFactory
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                connectionSection
                pairingSection
                testSection
            }
            .accessibilityIdentifier(AccessibilityID.AddAgent.screen)
            .navigationTitle(viewModel.isEditing ? "Edit Agent" : "Add Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.AddAgent.cancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            try? await viewModel.save()
                            dismiss()
                        }
                    }
                    .disabled(!viewModel.canSave)
                    .accessibilityIdentifier(AccessibilityID.AddAgent.saveButton)
                }
            }
        }
    }

    private var identitySection: some View {
        Section("Identity") {
            TextField("Name", text: $viewModel.name)
                .accessibilityIdentifier(AccessibilityID.AddAgent.nameField)
            TextField("Label (optional)", text: $viewModel.detail)
                .accessibilityIdentifier(AccessibilityID.AddAgent.detailField)
        }
    }

    private var connectionSection: some View {
        Section {
            Picker("Transport", selection: $viewModel.transportKind) {
                ForEach(TransportKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityIdentifier(AccessibilityID.AddAgent.transportPicker)

            TextField("Room URL", text: $viewModel.connectionURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier(AccessibilityID.AddAgent.urlField)

            SecureField("Token / API key", text: $viewModel.token)
                .accessibilityIdentifier(AccessibilityID.AddAgent.tokenField)
        } header: {
            Text("Connection")
        } footer: {
            Text("Two ways to connect, your choice: a direct room URL + token, or a pairing endpoint below. The token / API key is stored only in your device Keychain.")
        }
    }

    private var pairingSection: some View {
        Section {
            TextField("Pairing endpoint", text: $viewModel.pairingEndpointText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier(AccessibilityID.AddAgent.pairingField)

            TextField("Agent ID", text: $viewModel.pairingAgentID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(AccessibilityID.AddAgent.pairingAgentIDField)
        } header: {
            Text("Pairing (optional)")
        } footer: {
            Text("If set, the app POSTs this endpoint (bearer = the API key above) for a fresh room + token each call. Agent ID tells your server which agent to connect.")
        }
    }

    private var testSection: some View {
        Section {
            Button("Test Connection") {
                Task { await viewModel.testConnection() }
            }
            .disabled(!viewModel.canSave || viewModel.testState == .testing)
            .accessibilityIdentifier(AccessibilityID.AddAgent.testConnectionButton)

            testResultView
                .accessibilityIdentifier(AccessibilityID.AddAgent.testResult)
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        switch viewModel.testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack {
                ProgressView()
                Text("Testing…")
            }
            .foregroundStyle(.secondary)
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

}

#Preview {
    AddEditAgentSheet(environment: .inMemory())
}
