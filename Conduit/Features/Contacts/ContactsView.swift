//
//  ContactsView.swift
//  Conduit
//
//  The Contacts tab's root content: the user's agents, sorted by name, each a
//  row that pushes AgentDetail or places a call. Placed inside a NavigationStack
//  by the coordinator, so it owns the title, toolbar, and navigation destination
//  but not the stack itself.
//

import SwiftData
import SwiftUI

struct ContactsView: View {
    @Query(sort: [SortDescriptor(\Agent.name)]) private var agents: [Agent]
    @Environment(AppEnvironment.self) private var environment
    @State private var sheetRequest: AgentSheetRequest?

    /// What the add/edit sheet should show: a plain add, or one pre-filled from a
    /// conduit:// link (editing the existing agent when the link's pairing
    /// endpoint matches one — a re-scan updates instead of duplicating).
    private struct AgentSheetRequest: Identifiable {
        let id = UUID()
        let editing: Agent?
        let prefill: AgentDeepLink?
    }

    var body: some View {
        content
            .accessibilityIdentifier(AccessibilityID.Contacts.screen)
            .navigationTitle("Contacts")
            .brandMarkToolbar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Agent", systemImage: "plus") {
                        sheetRequest = AgentSheetRequest(editing: nil, prefill: nil)
                    }
                    .accessibilityIdentifier(AccessibilityID.Contacts.addButton)
                }
            }
            .navigationDestination(for: Agent.self) { agent in
                AgentDetailView(agent: agent)
            }
            .sheet(item: $sheetRequest) { request in
                AddEditAgentSheet(
                    editing: request.editing,
                    prefill: request.prefill,
                    environment: environment
                )
            }
            .onAppear { consumePendingLink() }
            .onChange(of: environment.pendingAgentLink) { _, _ in consumePendingLink() }
            // A link that arrived while a sheet or a call was up is consumed
            // once the way is clear.
            .onChange(of: sheetRequest == nil) { _, _ in consumePendingLink() }
            .onChange(of: environment.callSession.state.isActive) { _, _ in consumePendingLink() }
    }

    /// Present the pending conduit:// link's sheet — unless another sheet or an
    /// active call is in the way, in which case it stays pending.
    private func consumePendingLink() {
        guard let link = environment.pendingAgentLink else { return }
        guard sheetRequest == nil, !environment.callSession.state.isActive else { return }
        environment.pendingAgentLink = nil
        let existing = agents.first {
            $0.pairingEndpoint?.absoluteString == link.pairingEndpoint.absoluteString
        }
        sheetRequest = AgentSheetRequest(editing: existing, prefill: link)
    }

    @ViewBuilder
    private var content: some View {
        if agents.isEmpty {
            ContentUnavailableView {
                Label("No Agents", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Add an agent to start calling.")
            } actions: {
                Button("Add Agent") { sheetRequest = AgentSheetRequest(editing: nil, prefill: nil) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.Contacts.emptyAddButton)
                Link("Learn how to connect your agent", destination: ExternalLinks.connectYourAgent)
                    .font(.footnote)
                    .accessibilityIdentifier(AccessibilityID.Contacts.emptySetupLink)
            }
        } else {
            List {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    NavigationLink(value: agent) {
                        ContactRow(
                            agent: agent,
                            callButtonID: AccessibilityID.Contacts.callButton(index),
                            onCall: { Task { await environment.callSession.placeCall(agent) } }
                        )
                    }
                    .accessibilityIdentifier(AccessibilityID.Contacts.row(index))
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            delete(agent)
                        }
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Contacts.list)
        }
    }

    private func delete(_ agent: Agent) {
        Log.info(.ui, "Deleting agent from Contacts")
        // Capture before the SwiftData delete invalidates the model.
        let inboundEndpoint = agent.inboundRegistrationURL
        let apiKey = (try? environment.keychain.token(
            for: KeychainTokenRef(account: agent.keychainTokenRef)
        )) ?? nil
        try? environment.keychain.deleteToken(for: KeychainTokenRef(account: agent.keychainTokenRef))
        try? environment.keychain.deleteToken(for: KeychainTokenRef(directTokenForAgentID: agent.id))
        environment.agentRepository.delete(agent)
        try? environment.agentRepository.save()
        ConduitAppShortcuts.refreshParameters()
        if let inboundEndpoint {
            Task { await PushTokenRegistrar.unregister(endpoint: inboundEndpoint, apiKey: apiKey ?? "") }
        }
    }
}

#Preview {
    NavigationStack {
        ContactsView()
    }
    .environment(AppEnvironment.inMemory())
}
