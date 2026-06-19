//
//  InCallView.swift
//  Conduit
//
//  The full-screen call surface — a pure projection of `CallSessionCoordinator`.
//  Presented via `.fullScreenCover` from RootTabView, so it owns no NavigationStack.
//  Every control just forwards intent to the coordinator; all call logic lives there.
//

import AVFoundation
import SwiftUI

struct InCallView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SettingsStore.pushToTalkKey) private var pushToTalk = false
    @State private var isHolding = false
    @State private var activeRouteKind: AudioRouteKind = .other

    private var coordinator: CallSessionCoordinator { environment.callSession }

    // MARK: - Adaptive call surface
    // The call screen follows the system appearance: white-on-dark in dark mode,
    // dark-on-light in light mode. The agent color stays vivid (dark-resolved) in
    // both, so an agent keeps its identity; `onSurface`/`surfaceBase` keep every
    // label and control legible whichever way the gradient fades.

    /// The primary foreground for the name, status, and control glyphs.
    private var onSurface: Color { colorScheme == .dark ? .white : .black }
    /// The color the background gradient fades to (and the opaque base behind it).
    private var surfaceBase: Color { colorScheme == .dark ? .black : .white }
    /// The unfilled control-circle fill — a faint wash of the surface's opposite.
    private var controlFill: Color {
        colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.06)
    }

    var body: some View {
        let state = coordinator.state

        ZStack {
            background

            VStack(spacing: 0) {
                topBar(state: state)
                header(state: state)
                Spacer()
                avatar
                Spacer()
                controls(state: state)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .tint(onSurface)
        .accessibilityIdentifier(AccessibilityID.InCall.screen)
        .onAppear { activeRouteKind = .active }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            activeRouteKind = .active
        }
        #if DEBUG
        .task { await traceCall() }
        #endif
    }

    #if DEBUG
    /// Poll the coordinator and log every change for the duration this screen is up
    /// (i.e. the call). Pulled off-device to diagnose mute/state behavior.
    private func traceCall() async {
        CallTrace.reset()
        CallTrace.record("trace start")
        var last = ""
        while !Task.isCancelled {
            let c = coordinator
            let devices = c.audioDevices.map { "\($0.id)|\($0.name)" }.joined(separator: " ;; ")
            let route = AVAudioSession.sharedInstance().currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            let snapshot = """
            state=\(c.state) muted=\(c.isMuted) audioActivated=\(c.isAudioActivated) \
            selected=\(c.selectedAudioDeviceID ?? "nil") activeRoute=[\(route)] devices=[\(devices)]
            """
            if snapshot != last {
                CallTrace.record(snapshot)
                last = snapshot
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        CallTrace.record("trace end")
    }
    #endif

    // MARK: - Background

    /// The active agent's identity color (name-derived placeholder when there's no
    /// agent yet). Resolved dark, matching `AgentColor`, so it's stable.
    private var agentColor: Color {
        (coordinator.activeAgent?.paletteColor ?? .derived(forName: "Agent")).color
    }

    private var background: some View {
        ZStack(alignment: .top) {
            // Opaque base — the wash below uses agent-color opacity, so without this
            // the screen (an overlay, not a modal cover) would show the tabs through it.
            surfaceBase
            // A top-down wash in the agent's color — a quieter echo of the avatar,
            // fading to the surface base where the controls sit.
            LinearGradient(
                stops: [
                    .init(color: agentColor.opacity(0.55), location: 0),
                    .init(color: agentColor.opacity(0.18), location: 0.35),
                    .init(color: surfaceBase, location: 0.72),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // Dark mode only: a thin top scrim so the white name/status stay legible
            // on lighter palette colors (orange/teal). In light mode the labels are
            // dark, so the scrim would only muddy the wash.
            if colorScheme == .dark {
                LinearGradient(
                    colors: [.black.opacity(0.35), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 300)
                .frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar (minimize)

    @ViewBuilder
    private func topBar(state: CallState) -> some View {
        HStack {
            if !state.isTerminal {
                Button {
                    environment.isCallScreenMinimized = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(onSurface)
                        .frame(width: 44, height: 44)
                        .background(controlFill, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimize")
                .accessibilityIdentifier(AccessibilityID.InCall.closeButton)
            }
            Spacer()
        }
    }

    // MARK: - Header

    private func header(state: CallState) -> some View {
        VStack(spacing: 8) {
            Text(coordinator.activeAgent?.name ?? "Agent")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(onSurface)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(AccessibilityID.InCall.agentName)

            statusLine(state: state)

            if case .failed(let reason) = state {
                Text(reason.hint)
                    .font(.footnote)
                    .foregroundStyle(onSurface.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(AccessibilityID.InCall.failureHint)
            }
        }
    }

    @ViewBuilder
    private func statusLine(state: CallState) -> some View {
        Group {
            if coordinator.isInterrupted {
                Text("Paused")
            } else if case .connected(let since) = state {
                HStack(spacing: 4) {
                    if let transport = coordinator.activeAgent?.transportKind.displayName {
                        Text("\(transport) ·")
                    }
                    Text(since, style: .timer)
                        .monospacedDigit()
                }
            } else if !coordinator.endedByUser, let text = InCallStatus.text(for: state) {
                Text(text)
            } else {
                Text(" ")
            }
        }
        .font(.title3)
        .foregroundStyle(onSurface.opacity(0.7))
        .contentTransition(.identity)
        .accessibilityIdentifier(AccessibilityID.InCall.statusLabel)
    }

    // MARK: - Avatar

    private var avatar: some View {
        AgentAvatarView(
            name: coordinator.activeAgent?.name ?? "Agent",
            imageData: coordinator.activeAgent?.avatarData,
            color: coordinator.activeAgent?.paletteColor,
            size: 180
        )
        .activeSpeakerRing(isActive: coordinator.isBotSpeaking, color: agentColor)
    }

    // MARK: - Controls

    @ViewBuilder
    private func controls(state: CallState) -> some View {
        // A user-ended call is dismissed immediately by RootTabView; keep the active
        // controls during the slide-away so no "Call Ended" page flashes. Remote
        // hangups / failures (endedByUser == false) show their terminal page + Close.
        if state.isTerminal && !coordinator.endedByUser {
            terminalControls
        } else {
            activeControls
        }
    }

    private var activeControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                micControl
                routeButton
                endButton
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: .capsule)

            if pushToTalk {
                Text("Hold to Talk")
                    .font(.caption)
                    .foregroundStyle(onSurface.opacity(0.7))
            }
        }
    }

    private var terminalControls: some View {
        Button("Close") {
            coordinator.reset()
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(onSurface)
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
        .background(controlFill, in: .capsule)
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

    // A Daily-backed route menu (speaker / earpiece / Bluetooth / AirPods). Routing
    // goes through the transport because the SDK manages its own audio session and
    // re-asserts its choice — AVRoutePickerView (AirPlay) just fought it.
    private var routeButton: some View {
        Menu {
            Picker("Audio Output", selection: routeSelection) {
                ForEach(sortedDevices) { device in
                    let kind = AudioRouteKind(deviceID: device.id)
                    Label(displayName(for: kind), systemImage: kind.iconName)
                        .tag(Optional(device.id))
                }
            }
        } label: {
            controlCircle(systemImage: activeRouteKind.iconName, filled: false)
        }
        .accessibilityLabel("Audio Output")
        .accessibilityIdentifier(AccessibilityID.InCall.routePicker)
    }

    private var sortedDevices: [AudioDeviceInfo] {
        coordinator.audioDevices.sorted {
            AudioRouteKind(deviceID: $0.id).sortRank < AudioRouteKind(deviceID: $1.id).sortRank
        }
    }

    /// The Picker's selection is the route that's ACTUALLY active (from
    /// AVAudioSession), not the transport's preferred device — which stays nil
    /// until the user explicitly picks one, so the checkmark would never show.
    private var routeSelection: Binding<String?> {
        Binding(
            get: { activeDeviceID },
            set: { if let id = $0 { Task { await coordinator.selectAudioDevice(id) } } }
        )
    }

    private var activeDeviceID: String? {
        coordinator.audioDevices.first { AudioRouteKind(deviceID: $0.id) == activeRouteKind }?.id
    }

    /// Friendly route label. For Bluetooth, use the system's real device name
    /// ("AirPods Pro", the car's name) from AVAudioSession — Daily only reports it
    /// generically as "Bluetooth Speaker & Mic".
    private func displayName(for kind: AudioRouteKind) -> String {
        if kind == .bluetooth, let name = bluetoothRouteName { return name }
        return kind.displayName
    }

    private var bluetoothRouteName: String? {
        AVAudioSession.sharedInstance().availableInputs?
            .first { AudioRouteKind(portType: $0.portType) == .bluetooth }?
            .portName
    }

    // MARK: - End button

    private var endButton: some View {
        Button {
            // Mark the user-end so RootTabView dismisses the cover instantly (no
            // slide-down), then tear the call down.
            coordinator.markEndedByUser()
            Task { await coordinator.endCall() }
        } label: {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(.red, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End Call")
        .accessibilityIdentifier(AccessibilityID.InCall.endButton)
    }

    // MARK: - Shared control styling

    private func controlCircle(systemImage: String, filled: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(filled ? surfaceBase : onSurface)
            .frame(width: 60, height: 60)
            .background(filled ? AnyShapeStyle(onSurface) : AnyShapeStyle(controlFill), in: .circle)
    }
}

#Preview {
    // Layout preview only — state is `.idle`; a live preview needs a placed call.
    InCallView()
        .environment(AppEnvironment.inMemory())
}
