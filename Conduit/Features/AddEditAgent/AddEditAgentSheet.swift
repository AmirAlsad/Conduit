//
//  AddEditAgentSheet.swift
//  Conduit
//
//  The bring-your-own-agent form, presented modally for both adding a new agent
//  and editing an existing one. A thin projection over `AddEditAgentViewModel`;
//  all validation, persistence, and test-connection logic lives there.
//

import PhotosUI
import SwiftUI

struct AddEditAgentSheet: View {
    @State private var viewModel: AddEditAgentViewModel
    @State private var photoItem: PhotosPickerItem?
    @State private var directExpanded: Bool
    @Environment(\.dismiss) private var dismiss

    init(editing: Agent? = nil, environment: AppEnvironment) {
        _viewModel = State(
            initialValue: AddEditAgentViewModel(
                editing: editing,
                repository: environment.agentRepository,
                keychain: environment.keychain,
                contactSync: environment.contactSync,
                transportFactory: environment.transportFactory,
                inboundRegistrar: environment.inboundRegistrar
            )
        )
        // Reveal direct credentials only when the agent already uses them.
        _directExpanded = State(initialValue: editing?.connectionURL != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                pairingSection
                directSection
                inboundSection
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
            avatarPicker
            TextField("Name", text: $viewModel.name)
                .accessibilityIdentifier(AccessibilityID.AddAgent.nameField)
            TextField("Label (optional)", text: $viewModel.detail)
                .accessibilityIdentifier(AccessibilityID.AddAgent.detailField)
        }
    }

    private var avatarPicker: some View {
        let hasPhoto = viewModel.avatarData != nil
        return VStack(spacing: 12) {
            AgentAvatarView(name: viewModel.name, imageData: viewModel.avatarData, size: 88)

            PhotosPicker(
                selection: $photoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Text(hasPhoto ? "Change Photo" : "Add Photo")
            }
            .accessibilityIdentifier(AccessibilityID.AddAgent.photoPicker)

            if hasPhoto {
                Button("Remove Photo", role: .destructive) {
                    viewModel.avatarData = nil
                    photoItem = nil
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .onChange(of: photoItem) { _, item in
            Task { await loadAvatar(item) }
        }
    }

    @MainActor
    private func loadAvatar(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        let avatar = await Task.detached { UIImage(data: data)?.conduitAvatarData() }.value
        viewModel.avatarData = avatar ?? data
    }

    private var pairingSection: some View {
        Section {
            Picker("Transport", selection: $viewModel.transportKind) {
                ForEach(TransportKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityIdentifier(AccessibilityID.AddAgent.transportPicker)

            TextField("Pairing endpoint", text: $viewModel.pairingEndpointText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier(AccessibilityID.AddAgent.pairingField)

            SecureField("API key", text: $viewModel.apiKey)
                .accessibilityIdentifier(AccessibilityID.AddAgent.apiKeyField)
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Conduit calls this endpoint for fresh credentials each call; the key stays in your Keychain.")
                Link("Learn more", destination: ExternalLinks.pairingDocs)
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.AddAgent.pairingDocsLink)
                if viewModel.transportKind == .daily {
                    Label {
                        Text("On Daily, switch audio output from Conduit's in-call controls. [Learn more](\(ExternalLinks.dailyAudioDocs.absoluteString))")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityIdentifier(AccessibilityID.AddAgent.dailyAudioNotice)
                }
            }
        }
    }

    private var directSection: some View {
        Section {
            DisclosureGroup("Direct room (advanced)", isExpanded: $directExpanded) {
                TextField("Room URL", text: $viewModel.connectionURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier(AccessibilityID.AddAgent.urlField)

                SecureField("Token (optional)", text: $viewModel.directToken)
                    .accessibilityIdentifier(AccessibilityID.AddAgent.directTokenField)
            }
            .accessibilityIdentifier(AccessibilityID.AddAgent.directDisclosure)
        } footer: {
            Text("Connect straight to a room URL instead of pairing — pairing wins if both are set. [Learn more](\(ExternalLinks.directRoomDocs.absoluteString))")
        }
    }

    private var inboundSection: some View {
        Section {
            Toggle("Let this agent call me", isOn: $viewModel.inboundEnabled)
                .accessibilityIdentifier(AccessibilityID.AddAgent.inboundToggle)
                .onChange(of: viewModel.inboundEnabled) { _, enabled in
                    if enabled { viewModel.prefillInboundURLIfNeeded() }
                }

            if viewModel.inboundEnabled {
                TextField("Registration endpoint", text: $viewModel.inboundRegistrationURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier(AccessibilityID.AddAgent.inboundURLField)
            }
        } header: {
            Text("Inbound Calls")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sends this device's push token to your own server so this agent can ring you.")
                Link("Learn more", destination: ExternalLinks.inboundCalls)
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.AddAgent.inboundDocsLink)
            }
        }
    }

    private var testSection: some View {
        Section {
            Button("Test Connection") {
                Task { await viewModel.testConnection() }
            }
            .disabled(!viewModel.canSave || viewModel.testState == .testing)
            .accessibilityIdentifier(AccessibilityID.AddAgent.testConnectionButton)

            if !viewModel.diagnosticSteps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.diagnosticSteps) { step in
                        diagnosticRow(step)
                            .accessibilityIdentifier(AccessibilityID.AddAgent.diagnosticRow(step.stage))
                    }
                }
                .accessibilityIdentifier(AccessibilityID.AddAgent.testResult)
            }
        }
    }

    private func diagnosticRow(_ step: DiagnosticStep) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                diagnosticIcon(step.status)
                Text(step.stage.title)
                    .foregroundStyle(step.status == .pending ? .secondary : .primary)
            }
            if case .failed(let message) = step.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.leading, 28)
            }
        }
    }

    @ViewBuilder
    private func diagnosticIcon(_ status: DiagnosticStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

}

#Preview {
    AddEditAgentSheet(environment: .inMemory())
}
