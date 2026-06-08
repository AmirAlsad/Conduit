//
//  AgentAvatarView.swift
//  Conduit
//
//  The agent's circular avatar, shared across Recents, Contacts, AgentDetail, and
//  InCall. Falls back to initials on a per-agent color when there's no photo. The
//  color is derived from the name with a stable hash (NOT `hashValue`, which is
//  seeded per process), so an agent keeps the same color across launches.
//

import SwiftUI

struct AgentAvatarView: View {
    let name: String
    let imageData: Data?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                initialsCircle
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var initialsCircle: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.85),
                        Color(hue: hue, saturation: 0.70, brightness: 0.65),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
    }

    private var initials: String {
        let letters = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
        return letters.isEmpty ? "?" : letters
    }

    /// Deterministic hue in 0...1 from the name's scalars (stable across launches).
    private var hue: Double {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double(sum % 360) / 360
    }
}

#Preview {
    HStack(spacing: 16) {
        AgentAvatarView(name: "Jarvis", imageData: nil, size: 64)
        AgentAvatarView(name: "Echo Bot", imageData: nil, size: 64)
        AgentAvatarView(name: "", imageData: nil, size: 64)
    }
    .padding()
}
