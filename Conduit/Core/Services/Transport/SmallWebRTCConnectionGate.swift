//
//  SmallWebRTCConnectionGate.swift
//  Conduit
//
//  Decides what a SmallWebRTC connect attempt reports, what `connect(_:)` does
//  with the session it finds, whether a call-control signal can reach the agent,
//  and which of several overlapping connects still owns the transport. Pure and
//  SDK-free so every rule is unit-testable; the same rules as the package's Daily
//  adapter, whose Pipecat client this one shares.
//
//  An attempt is over once it has reported a disconnect, its connect has thrown, or
//  the host has asked to disconnect. From then on the gate reports nothing that
//  would steer the engine: Pipecat callbacks from a dropped call can still arrive
//  while the engine runs the target's credential code for its next attempt, and a
//  late bot-left would end a reconnecting call, a second drop would spend another
//  retry.
//
//  A connect that finds the session still up reports `.connected` again only for a
//  live attempt whose agent is ready. Anything else still up (a join in flight, a
//  joined session whose bot never got ready, an attempt that is over, a session
//  leaving) is taken over: the engine has given up on it and brings fresh
//  credentials, so the adapter leaves that session without the end-call signal,
//  releases its client and joins with a new one. The SDK heals nothing by itself
//  (a failed ICE connection ends the session), so there is no recovery to wait for.
//

import ConduitCallEngine

/// The session's state, as far as a new connect or a signal is concerned.
enum SmallWebRTCSessionPhase: Equatable {
    /// Nothing joined or joining: a connect can start at once.
    case idle
    /// A join is under way and the data channel is not open yet.
    case negotiating
    /// Joined (the data channel is open), and the agent is not ready yet.
    case awaitingBot
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
    /// Leave the session without the end-call signal, release its client, and join
    /// with a new one.
    case takeOver
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
        case .ready: isLive ? .reportConnected : .takeOver
        case .awaitingBot: isLive && reportedConnected ? .reportConnected : .takeOver
        case .negotiating, .leaving: .takeOver
        }
    }

    /// Whether a call-control signal sent now reaches the agent: the data channel is
    /// open and this attempt still has an agent to hear it.
    func carriesSignals(in phase: SmallWebRTCSessionPhase) -> Bool {
        guard isLive else { return false }
        switch phase {
        case .awaitingBot, .ready: return true
        case .idle, .negotiating, .leaving: return false
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

/// Which `connect(_:)` owns the transport. Each connect takes a ticket; once another
/// connect or a `disconnect()` has begun since, the connect no longer owns anything:
/// whoever came later has already dealt with its session, so it must not touch the
/// transport again, only throw.
struct SmallWebRTCConnectLedger {
    struct Ticket: Equatable {
        fileprivate let connect: Int
        fileprivate let disconnects: Int
    }

    enum Standing: Equatable {
        /// No connect or disconnect has begun since: this connect owns the transport.
        case current
        /// A newer connect has begun (and takes the session over).
        case superseded
        /// The host disconnected.
        case disconnected
    }

    private var connects = 0
    private var disconnects = 0

    mutating func connectDidBegin() -> Ticket {
        connects += 1
        return Ticket(connect: connects, disconnects: disconnects)
    }

    mutating func disconnectDidBegin() {
        disconnects += 1
    }

    func standing(of ticket: Ticket) -> Standing {
        if ticket.disconnects != disconnects { return .disconnected }
        if ticket.connect != connects { return .superseded }
        return .current
    }
}
