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
    @State private var showingAdd = false

    var body: some View {
        content
            .accessibilityIdentifier(AccessibilityID.Contacts.screen)
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Agent", systemImage: "plus") {
                        showingAdd = true
                    }
                    .accessibilityIdentifier(AccessibilityID.Contacts.addButton)
                }
            }
            .navigationDestination(for: Agent.self) { agent in
                AgentDetailView(agent: agent)
            }
            .sheet(isPresented: $showingAdd) {
                AddEditAgentSheet(environment: environment)
            }
    }

    @ViewBuilder
    private var content: some View {
        if agents.isEmpty {
            ContentUnavailableView(
                "No Agents",
                systemImage: "person.crop.circle.badge.plus",
                description: Text("Add an agent to start calling.")
            )
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
        environment.agentRepository.delete(agent)
        try? environment.agentRepository.save()
    }
}

#Preview {
    NavigationStack {
        ContactsView()
    }
    .environment(AppEnvironment.inMemory())
}
