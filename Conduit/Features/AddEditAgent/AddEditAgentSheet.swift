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
    @Environment(\.dismiss) private var dismiss

    init(editing: Agent? = nil, environment: AppEnvironment) {
        _viewModel = State(
            initialValue: AddEditAgentViewModel(
                editing: editing,
                repository: environment.agentRepository,
                keychain: environment.keychain,
                contactSync: environment.contactSync,
                transportFactory: environment.transportFactory
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                pairingSection
                directSection
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

            SecureField("API key", text: $viewModel.token)
                .accessibilityIdentifier(AccessibilityID.AddAgent.tokenField)
        } header: {
            Text("Connection")
        } footer: {
            Text("Conduit POSTs this endpoint with your API key as a bearer token to get a fresh room and token for each call — the usual setup for a Pipecat or LiveKit server. The endpoint identifies the agent, so for multiple agents use one endpoint each. The key is stored only in your device Keychain.")
        }
    }

    private var directSection: some View {
        Section {
            TextField("Room URL", text: $viewModel.connectionURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier(AccessibilityID.AddAgent.urlField)
        } header: {
            Text("Direct room (advanced)")
        } footer: {
            Text("Optional. Skip pairing and connect straight to a room URL, using the key above as the room token.")
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
