//
//  FakeCallProvider.swift
//  Conduit
//
//  In-app fake conforming to `CallProviding`, plus `FakeAudioSession` for driving
//  the activation handshake. A test drives the system → app direction
//  (`simulateActivate`, `simulateEndCall`, …) and asserts on what was reported.
//

import Foundation

@MainActor
final class FakeCallProvider: CallProviding {
    weak var delegate: CallProviderDelegate?

    private(set) var startedCalls: [UUID] = []
    private(set) var startedHandles: [CallHandle] = []
    private(set) var reportedConnecting: [UUID] = []
    private(set) var reportedConnected: [UUID] = []
    private(set) var endRequests: [UUID] = []
    private(set) var reportedEnded: [(id: UUID, reason: CallEndReason)] = []
    private(set) var muteStates: [UUID: Bool] = [:]
    private(set) var holdStates: [UUID: Bool] = [:]

    /// When set, the next `startOutgoingCall` throws this.
    var startError: Error?
    /// The UUID handed back from the next `startOutgoingCall`.
    var nextCallID = UUID()

    func startOutgoingCall(handle: CallHandle, displayName: String) async throws -> UUID {
        if let startError { throw startError }
        let id = nextCallID
        startedCalls.append(id)
        startedHandles.append(handle)
        return id
    }

    func reportOutgoingCallConnecting(_ id: UUID) { reportedConnecting.append(id) }
    func reportOutgoingCallConnected(_ id: UUID) { reportedConnected.append(id) }
    func endCall(_ id: UUID) async { endRequests.append(id) }
    func reportCallEnded(_ id: UUID, reason: CallEndReason) { reportedEnded.append((id, reason)) }
    func setMuted(_ id: UUID, muted: Bool) async { muteStates[id] = muted }
    func setOnHold(_ id: UUID, held: Bool) async { holdStates[id] = held }

    // MARK: - System → app drivers (for tests / debug path)

    func simulateActivate(_ session: AudioSessionActivating) {
        delegate?.providerDidActivate(session)
    }

    func simulateDeactivate(_ session: AudioSessionActivating) {
        delegate?.providerDidDeactivate(session)
    }

    func simulateEndCall(_ id: UUID) { delegate?.providerPerformEndCall(id) }
    func simulateSetMuted(_ id: UUID, muted: Bool) { delegate?.providerPerformSetMuted(id, muted: muted) }
    func simulateReset() { delegate?.providerWasReset() }
}

@MainActor
final class FakeAudioSession: AudioSessionActivating {
    var hasExternalAudioRoute: Bool
    private(set) var didOverrideToSpeaker = false
    private(set) var didClearOverride = false

    init(hasExternalAudioRoute: Bool = false) {
        self.hasExternalAudioRoute = hasExternalAudioRoute
    }

    func overrideOutputToSpeaker() throws { didOverrideToSpeaker = true }
    func clearOutputOverride() throws { didClearOverride = true }
}
