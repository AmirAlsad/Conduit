//
//  AgentDetailView.swift
//  Conduit
//
//  The per-agent detail screen: header card, the prominent Call action, the call
//  history, and the edit/delete affordances. Pushed inside an existing
//  NavigationStack — it does not own one.
//

import SwiftUI

struct AgentDetailView: View {
    let agent: Agent

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var showingEdit = false
    @State private var showingAddContact = false
    @State private var confirmingDelete = false

    private var sortedLog: [CallLogEntry] {
        agent.callLog.sorted { $0.startedAt > $1.startedAt }
    }

    /// The host of whichever connection the agent uses (direct room or pairing endpoint).
    private var connectionSummary: String {
        if let host = agent.connectionURL?.host() ?? agent.pairingEndpoint?.host() { return host }
        return agent.connectionURL?.absoluteString ?? agent.pairingEndpoint?.absoluteString ?? "—"
    }

    var body: some View {
        List {
            header
            contactSection
            callHistory
            deleteSection
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(AccessibilityID.AgentDetail.screen)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEdit = true }
                    .accessibilityIdentifier(AccessibilityID.AgentDetail.editButton)
            }
        }
        .sheet(isPresented: $showingEdit) {
            AddEditAgentSheet(editing: agent, environment: environment)
        }
        .sheet(isPresented: $showingAddContact) {
            NewContactView(info: mirrorInfo) { savedID in
                if let savedID { saveContactIdentifier(savedID) }
                showingAddContact = false
            }
            .ignoresSafeArea()
        }
        .confirmationDialog(
            "Delete \(agent.name)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteAgent)
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    /// Header card + the Call row share one section so the action sits tight
    /// under the identity block instead of a full section-gap below it.
    private var header: some View {
        Section {
            VStack(spacing: 8) {
                AgentAvatarView(name: agent.name, imageData: agent.avatarData, size: 88)

                Text(agent.name)
                    .font(.title2)
                    .bold()

                if !agent.detail.isEmpty {
                    Text(agent.detail)
                        .foregroundStyle(.secondary)
                }

                Text(agent.transportKind.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.15), in: .capsule)
                    .foregroundStyle(.tint)

                Text(connectionSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Button {
                Task { await environment.callSession.placeCall(agent) }
            } label: {
                Label("Call", systemImage: "phone.fill")
            }
            .foregroundStyle(.green)
            .accessibilityIdentifier(AccessibilityID.AgentDetail.callButton)
        }
    }

    // MARK: - Contact

    @ViewBuilder
    private var contactSection: some View {
        Section {
            if agent.contactIdentifier == nil {
                Button {
                    showingAddContact = true
                } label: {
                    Label("Add to Contacts", systemImage: "person.crop.circle.badge.plus")
                }
                .accessibilityIdentifier(AccessibilityID.AgentDetail.addToContactsButton)
            } else {
                Label("Added to Contacts", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.AgentDetail.addToContactsButton)
            }
        } footer: {
            Text("Adds a contact so this agent appears on the call and lock screens. [Learn more.](\(ExternalLinks.contactMirrorDocs.absoluteString))")
        }
    }

    private var mirrorInfo: AgentMirrorInfo {
        AgentMirrorInfo(
            id: agent.id,
            displayName: agent.name,
            avatarData: agent.avatarData,
            syntheticEmail: agent.syntheticEmail
        )
    }

    private func saveContactIdentifier(_ identifier: String) {
        agent.contactIdentifier = identifier
        try? environment.agentRepository.save()
    }

    // MARK: - Call history

    private var callHistory: some View {
        Section("Call History") {
            if agent.callLog.isEmpty {
                Text("No calls yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(sortedLog.enumerated()), id: \.element.id) { index, entry in
                    logRow(entry, index: index)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.AgentDetail.log)
    }

    private func logRow(_ entry: CallLogEntry, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.outcome.iconName)
                .foregroundStyle(entry.outcome.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.outcomeDisplayLabel)
                Text(CallFormatting.relativeDate(entry.startedAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if entry.outcome == .completed && entry.duration > 0 {
                Text(CallFormatting.duration(entry.duration))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityIdentifier(AccessibilityID.AgentDetail.logRow(index))
    }

    // MARK: - Delete

    private var deleteSection: some View {
        Section {
            Button("Delete Agent", role: .destructive) {
                confirmingDelete = true
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(AccessibilityID.AgentDetail.deleteButton)
        }
    }

    private func deleteAgent() {
        // Capture before the SwiftData delete invalidates the model.
        let inboundEndpoint = agent.inboundRegistrationURL
        let apiKey = (try? environment.keychain.token(
            for: KeychainTokenRef(account: agent.keychainTokenRef)
        )) ?? nil
        try? environment.keychain.deleteToken(
            for: KeychainTokenRef(account: agent.keychainTokenRef)
        )
        try? environment.keychain.deleteToken(
            for: KeychainTokenRef(directTokenForAgentID: agent.id)
        )
        environment.agentRepository.delete(agent)
        try? environment.agentRepository.save()
        if let inboundEndpoint {
            Task { await PushTokenRegistrar.unregister(endpoint: inboundEndpoint, apiKey: apiKey ?? "") }
        }
        dismiss()
    }
}

#Preview {
    let env = AppEnvironment.inMemory()
    let sample = Agent(
        name: "Echo Bot",
        transportKind: .daily,
        connectionURL: URL(string: "https://example.daily.co/room")!
    )
    env.modelContainer.mainContext.insert(sample)

    return NavigationStack {
        AgentDetailView(agent: sample)
    }
    .environment(env)
}
