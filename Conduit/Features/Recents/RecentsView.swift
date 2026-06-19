//
//  RecentsView.swift
//  Conduit
//
//  The Recents (call log) tab's root content, sorted newest-first. Tapping a row
//  redials its agent (Phone-app style); a trailing info button pushes the agent's
//  detail. Placed inside a NavigationStack by the coordinator, so it owns the
//  title, toolbar, and navigation destination but not the stack itself.
//

import SwiftData
import SwiftUI

struct RecentsView: View {
    @Query(sort: [SortDescriptor(\CallLogEntry.startedAt, order: .reverse)])
    private var entries: [CallLogEntry]
    @Environment(AppEnvironment.self) private var environment
    @State private var showingAdd = false

    var body: some View {
        content
            .accessibilityIdentifier(AccessibilityID.Recents.screen)
            .navigationTitle("Recents")
            .brandMarkToolbar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Agent", systemImage: "plus") {
                        showingAdd = true
                    }
                    .accessibilityIdentifier(AccessibilityID.Recents.addButton)
                }
            }
            .navigationDestination(for: CallLogEntry.self) { entry in
                if let agent = entry.agent {
                    AgentDetailView(agent: agent)
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddEditAgentSheet(environment: environment)
            }
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No Recent Calls",
                systemImage: "clock",
                description: Text("Calls to your agents will appear here.")
            )
        } else {
            List {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    row(for: entry, index: index)
                        .accessibilityIdentifier(AccessibilityID.Recents.row(index))
                }
            }
            .accessibilityIdentifier(AccessibilityID.Recents.list)
        }
    }

    @ViewBuilder
    private func row(for entry: CallLogEntry, index: Int) -> some View {
        Group {
            if let agent = entry.agent {
                NavigationLink(value: entry) {
                    RecentRow(entry: entry)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        Task { await environment.callSession.placeCall(agent) }
                    } label: {
                        Label("Call", systemImage: "phone.fill")
                    }
                    .tint(.green)
                    .accessibilityIdentifier(AccessibilityID.Recents.callButton(index))
                }
            } else {
                RecentRow(entry: entry)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) {
                delete(entry)
            }
            .accessibilityIdentifier(AccessibilityID.Recents.deleteButton(index))
        }
    }

    private func delete(_ entry: CallLogEntry) {
        Log.info(.ui, "Deleting call log entry")
        environment.agentRepository.deleteCallLogEntry(entry)
        try? environment.agentRepository.save()
    }
}

#Preview {
    NavigationStack {
        RecentsView()
    }
    .environment(AppEnvironment.inMemory())
}
