//
//  AgentAvatarView.swift
//  Conduit
//
//  The agent's circular avatar, shared across Recents, Contacts, AgentDetail, and
//  InCall. Falls back to a person glyph on the agent's color when there's no photo
//  (agent names rarely make sensible initials). Pass the agent's `paletteColor`;
//  `nil` derives the color from the name (live previews, the no-agent placeholder).
//

import SwiftUI

struct AgentAvatarView: View {
    let name: String
    let imageData: Data?
    var color: AgentColor?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                glyphCircle
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var glyphCircle: some View {
        Circle()
            .fill(resolvedColor.color)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.white)
            }
    }

    private var resolvedColor: AgentColor {
        color ?? .derived(forName: name)
    }
}

#Preview {
    VStack(spacing: 16) {
        HStack(spacing: 16) {
            AgentAvatarView(name: "Jarvis", imageData: nil, size: 64)
            AgentAvatarView(name: "Echo Bot", imageData: nil, size: 64)
            AgentAvatarView(name: "Devil's Advocate", imageData: nil, color: .teal, size: 64)
        }
        AgentAvatarView(name: "loopback", imageData: nil, size: 140)
    }
    .padding()
}
