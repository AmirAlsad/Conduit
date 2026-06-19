//
//  RecentRow.swift
//  Conduit
//
//  One entry in the Recents call log: avatar, agent name (red when the agent is
//  gone or the call failed), an outcome line, and a trailing duration for
//  completed calls. Mirrors a Phone recents row.
//

import SwiftUI

struct RecentRow: View {
    let entry: CallLogEntry

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatarView(name: agentName, imageData: entry.agent?.avatarData, color: entry.agent?.paletteColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(agentName)
                    .font(.headline)
                    .foregroundStyle(nameTint)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: entry.outcome.iconName)
                        .foregroundStyle(entry.outcome.tint)
                    Text("\(entry.outcomeDisplayLabel) · \(CallFormatting.relativeDate(entry.startedAt))")
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            if showsDuration {
                Text(CallFormatting.duration(entry.duration))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var agentName: String {
        entry.agent?.name ?? "Unknown agent"
    }

    private var nameTint: Color {
        entry.agent == nil || entry.outcome == .failed ? .red : .primary
    }

    private var showsDuration: Bool {
        entry.outcome == .completed && entry.duration > 0
    }
}

#Preview {
    List {
        RecentRow(
            entry: CallLogEntry(
                agent: Agent(
                    name: "Jarvis",
                    detail: "Personal assistant",
                    transportKind: .daily,
                    connectionURL: URL(string: "https://example.daily.co/room")!
                ),
                startedAt: .now.addingTimeInterval(-3600),
                duration: 187,
                outcome: .completed,
                transportKind: .daily
            )
        )
        RecentRow(
            entry: CallLogEntry(
                agent: Agent(
                    name: "Echo Bot",
                    transportKind: .livekit,
                    connectionURL: URL(string: "wss://example.livekit.cloud")!
                ),
                startedAt: .now.addingTimeInterval(-86_400),
                outcome: .failed,
                transportKind: .livekit
            )
        )
        RecentRow(
            entry: CallLogEntry(
                agent: nil,
                startedAt: .now.addingTimeInterval(-172_800),
                outcome: .canceled,
                transportKind: .daily
            )
        )
    }
}
