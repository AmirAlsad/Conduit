//
//  InCallView.swift
//  Conduit
//
//  The full-screen call surface — a pure projection of `CallSessionCoordinator`.
//  Presented via `.fullScreenCover` from RootTabView, so it owns no NavigationStack.
//  Every control just forwards intent to the coordinator; all call logic lives there.
//

import SwiftUI

struct InCallView: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage(SettingsStore.pushToTalkKey) private var pushToTalk = false
    @State private var isHolding = false

    private var coordinator: CallSessionCoordinator { environment.callSession }

    var body: some View {
        let state = coordinator.state

        ZStack {
            background

            VStack(spacing: 0) {
                header(state: state)
                Spacer()
                avatar
                Spacer()
                controls(state: state)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier(AccessibilityID.InCall.screen)
        .onChange(of: state.isTerminal) { _, isTerminal in
            guard isTerminal else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                coordinator.reset()
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        LinearGradient(
            colors: [Color(white: 0.10), .black],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Header

    private func header(state: CallState) -> some View {
        VStack(spacing: 8) {
            Text(coordinator.activeAgent?.name ?? "Agent")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(AccessibilityID.InCall.agentName)

            statusLine(state: state)
        }
    }

    @ViewBuilder
    private func statusLine(state: CallState) -> some View {
        Group {
            if case .connected(let since) = state {
                Text(since, style: .timer)
                    .monospacedDigit()
            } else if let text = InCallStatus.text(for: state) {
                Text(text)
            } else {
                Text(" ")
            }
        }
        .font(.title3)
        .foregroundStyle(.white.opacity(0.7))
        .contentTransition(.identity)
        .accessibilityIdentifier(AccessibilityID.InCall.statusLabel)
    }

    // MARK: - Avatar

    private var avatar: some View {
        AgentAvatarView(
            name: coordinator.activeAgent?.name ?? "Agent",
            imageData: coordinator.activeAgent?.avatarData,
            size: 140
        )
        .speakingGlow(isActive: coordinator.isBotSpeaking, level: coordinator.remoteAudioLevel)
    }

    // MARK: - Controls

    @ViewBuilder
    private func controls(state: CallState) -> some View {
        if state.isTerminal {
            terminalControls
        } else {
            activeControls
        }
    }

    private var activeControls: some View {
        VStack(spacing: 40) {
            HStack(spacing: 56) {
                micControl
                routePicker
            }
            endButton
        }
    }

    private var terminalControls: some View {
        Button("Close") {
            coordinator.reset()
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
        .background(.white.opacity(0.15), in: .capsule)
        .accessibilityIdentifier(AccessibilityID.InCall.closeButton)
    }

    // MARK: - Mic control

    @ViewBuilder
    private var micControl: some View {
        if pushToTalk {
            pushToTalkButton
        } else {
            muteButton
        }
    }

    private var muteButton: some View {
        let isMuted = coordinator.isMuted
        return Button {
            Task { await coordinator.setMuted(!coordinator.isMuted) }
        } label: {
            controlCircle(
                systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                filled: isMuted
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
        .accessibilityIdentifier(AccessibilityID.InCall.muteButton)
    }

    private var pushToTalkButton: some View {
        controlCircle(systemImage: "waveform", filled: isHolding)
            .overlay(alignment: .bottom) {
                Text("Hold to Talk")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize()
                    .offset(y: 22)
            }
            .contentShape(.circle)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        Task { await coordinator.setPushToTalkActive(true) }
                    }
                    .onEnded { _ in
                        isHolding = false
                        Task { await coordinator.setPushToTalkActive(false) }
                    }
            )
            .accessibilityLabel("Hold to Talk")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(AccessibilityID.InCall.pushToTalkButton)
    }

    // MARK: - Route picker

    private var routePicker: some View {
        RoutePickerView()
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.15), in: .circle)
            .accessibilityLabel("Audio Output")
            .accessibilityIdentifier(AccessibilityID.InCall.routePicker)
    }

    // MARK: - End button

    private var endButton: some View {
        Button {
            Task { await coordinator.endCall() }
        } label: {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(.red, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End Call")
        .accessibilityIdentifier(AccessibilityID.InCall.endButton)
    }

    // MARK: - Shared control styling

    private func controlCircle(systemImage: String, filled: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(filled ? .black : .white)
            .frame(width: 64, height: 64)
            .background(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.15)), in: .circle)
    }
}

#Preview {
    // Layout preview only — state is `.idle`; a live preview needs a placed call.
    InCallView()
        .environment(AppEnvironment.inMemory())
}
