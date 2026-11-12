//
//  SmallWebRTCConnectionGate.swift
//  Conduit
//
//  Decides what a SmallWebRTC connect attempt reports, and what `connect(_:)` does
//  with the session it finds. Pure and SDK-free so every rule is unit-testable;
//  the same rules as the package's Daily adapter, whose Pipecat client this one
//  shares.
//
//  An attempt is over once it has reported a disconnect, its connect has thrown, or
//  the host has asked to disconnect. From then on the gate reports nothing that
//  would steer the engine: Pipecat callbacks from a dropped call can still arrive
//  while the engine runs the target's credential code for its next attempt, and a
//  late bot-left would end a reconnecting call, a second drop would spend another
//  retry.
//
//  A connect that finds the session still up never resets what it reports: a live
//  attempt that is ready reports `.connected` again, one still joining is left to
//  finish, and a session whose attempt is over (or that is leaving) is replaced.
//

import ConduitCallEngine

/// The Pipecat client's state, as far as a new connect is concerned.
enum SmallWebRTCSessionPhase: Equatable {
    /// Nothing joined or joining: a connect can start at once.
    case idle
    /// A join is under way and has not reached ready.
    case joining
    /// Joined, and the agent is ready.
    case ready
    /// A disconnect is in progress.
    case leaving
}

/// What `connect(_:)` does with the session it finds.
enum SmallWebRTCConnectPlan: Equatable {
    /// Start a join on the current session.
    case join
    /// The live attempt is ready: report `.connected` and join nothing.
    case reportConnected
    /// The live attempt is still joining; it will report how it ends.
    case awaitJoinUnderWay
    /// Retire the session silently and join on a new one.
    case replaceSession
}

struct SmallWebRTCConnectionGate {
    private(set) var reportedConnected = false
    private(set) var isAttemptOver = false
    private(set) var userRequestedDisconnect = false

    /// Whether this attempt may still report errors and its outcome.
    var isLive: Bool { !isAttemptOver && !userRequestedDisconnect }

    func plan(for phase: SmallWebRTCSessionPhase) -> SmallWebRTCConnectPlan {
        switch phase {
        case .idle: .join
        case .ready: isLive ? .reportConnected : .replaceSession
        case .joining: isLive ? .awaitJoinUnderWay : .replaceSession
        case .leaving: .replaceSession
        }
    }

    mutating func connectDidStart() {
        self = SmallWebRTCConnectionGate()
    }

    /// The adapter's connect threw; that throw is how this attempt's failure is reported.
    mutating func connectDidFail() {
        isAttemptOver = true
    }

    mutating func userDidRequestDisconnect() {
        userRequestedDisconnect = true
    }

    /// The session is being replaced: nothing it does from now on is reported.
    mutating func retire() {
        isAttemptOver = true
        userRequestedDisconnect = true
    }

    mutating func transportDidBecomeReady() -> TransportEvent? {
        guard !reportedConnected, isLive else { return nil }
        reportedConnected = true
        return .connected
    }

    /// A connect found this attempt ready: tell the engine again, whatever was
    /// reported before, since the engine is asking after the session.
    mutating func reconfirmConnected() -> TransportEvent? {
        guard isLive else { return nil }
        reportedConnected = true
        return .connected
    }

    mutating func transportDidDisconnect() -> TransportEvent? {
        guard !isAttemptOver else { return nil }
        isAttemptOver = true
        return .disconnected(reason: userRequestedDisconnect ? .requestedByUser : .networkDropped)
    }

    /// The bot left. Reported even before ready, so a bot that leaves before the call
    /// connects ends it rather than leaving it connecting.
    mutating func botDidLeave() -> TransportEvent? {
        guard isLive else { return nil }
        isAttemptOver = true
        return .disconnected(reason: .botLeft)
    }
}
