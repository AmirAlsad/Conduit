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
    private(set) var reportedIncoming: [(id: UUID, handle: CallHandle, displayName: String)] = []
    private(set) var updatedCalls: [(id: UUID, handle: CallHandle, displayName: String)] = []
    private(set) var reportedConnecting: [UUID] = []
    private(set) var reportedConnected: [UUID] = []
    private(set) var endRequests: [UUID] = []
    private(set) var reportedEnded: [(id: UUID, reason: CallEndReason)] = []
    private(set) var muteStates: [UUID: Bool] = [:]

    /// When set, the next `startOutgoingCall` throws this.
    var startError: Error?
    /// When set, `reportIncomingCall` completes with this error.
    var reportIncomingError: IncomingCallReportError?
    /// When true, `reportIncomingCall` holds its completion until
    /// `completeIncomingReports()` (real CallKit completes later); when false it
    /// completes before returning.
    var completesIncomingReportsLater = false
    private var pendingIncomingCompletions: [@MainActor () -> Void] = []
    /// Receives a label for each call into the provider, so a test can assert the
    /// order of provider calls against other events in one log.
    var onEvent: ((String) -> Void)?
    /// The UUID handed back from the next `startOutgoingCall`.
    var nextCallID = UUID()

    /// When true, `startOutgoingCall` suspends until `releaseStart()` — lets a test
    /// act while CallKit is still starting the call.
    var suspendStart = false
    private(set) var pendingStartCount = 0
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func releaseStart() {
        let waiting = startContinuations
        startContinuations = []
        pendingStartCount = 0
        waiting.forEach { $0.resume() }
    }

    func startOutgoingCall(handle: CallHandle, displayName: String) async throws -> UUID {
        let id = nextCallID
        if suspendStart {
            pendingStartCount += 1
            await withCheckedContinuation { startContinuations.append($0) }
        }
        if let startError { throw startError }
        startedCalls.append(id)
        startedHandles.append(handle)
        return id
    }

    func reportIncomingCall(
        id: UUID,
        handle: CallHandle,
        displayName: String,
        completion: @escaping @MainActor (IncomingCallReportError?) -> Void
    ) {
        onEvent?("report")
        let error = reportIncomingError
        reportedIncoming.append((id, handle, displayName))
        let complete: @MainActor () -> Void = { [weak self] in
            self?.onEvent?("report-completed")
            completion(error)
        }
        if completesIncomingReportsLater {
            pendingIncomingCompletions.append(complete)
        } else {
            complete()
        }
    }

    /// Deliver every held `reportIncomingCall` completion, in report order.
    func completeIncomingReports() {
        let pending = pendingIncomingCompletions
        pendingIncomingCompletions = []
        pending.forEach { $0() }
    }

    func updateCall(_ id: UUID, handle: CallHandle, displayName: String) {
        onEvent?("update")
        updatedCalls.append((id, handle, displayName))
    }

    func reportOutgoingCallConnecting(_ id: UUID) { reportedConnecting.append(id) }
    func reportOutgoingCallConnected(_ id: UUID) {
        onEvent?("reported-connected")
        reportedConnected.append(id)
    }
    func endCall(_ id: UUID) async {
        onEvent?("end-request")
        endRequests.append(id)
    }

    func reportCallEnded(_ id: UUID, reason: CallEndReason) {
        onEvent?("ended(\(reason))")
        reportedEnded.append((id, reason))
    }
    func setMuted(_ id: UUID, muted: Bool) async { muteStates[id] = muted }

    // MARK: - System → app drivers (for tests / debug path)

    func simulateActivate(_ session: AudioSessionActivating) {
        delegate?.providerDidActivate(session)
    }

    func simulateDeactivate(_ session: AudioSessionActivating) {
        delegate?.providerDidDeactivate(session)
    }

    func simulateAnswerCall(_ id: UUID) { delegate?.providerPerformAnswerCall(id) }
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
