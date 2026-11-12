//
//  SmallWebRTCAudioRouteGate.swift
//  Conduit
//
//  Decides which audio route the SmallWebRTC transport asks the SDK to prefer, and
//  when. Pure and SDK-free so every rule is unit-testable; the rules of the
//  package's `DailyAudioRouteGate`, fitted to what the SmallWebRTC SDK does.
//
//  The SDK's audio manager configures the shared audio session itself from the
//  moment its client initialises devices (at the start of every join). With no
//  preferred device it sets the video-chat mode, which iOS plays on the
//  loudspeaker, and it re-applies that after every route change. A preferred
//  device is kept by the SDK's client from the moment it is given, before the
//  join included, and is what the SDK applies when it starts managing the session
//  and after every route change. So the transport gives each new client the
//  wanted route before its join.
//
//  The wanted route is the engine's request (the speaker default, the user's
//  pick), which wins from the moment it is made, or else the route the call is on
//  at the first attach, once CallKit has activated the session. A join that starts
//  before the first attach takes the session's route at that moment (as the
//  engine pre-configured it for the call) as a provisional route, so the SDK does
//  not configure its loudspeaker default first and leave the first attach reading
//  it; a provisional loudspeaker is taken as the earpiece, where a call with no
//  speaker request starts. The first attach's reading replaces it. A route the
//  transport cannot name to the SDK (car audio, AirPlay, USB) is left to the SDK.
//
//  While no request was made, a Bluetooth or wired device that appears in the
//  SDK's device list is followed, as a phone call moves to a headset connected
//  during it; when the followed device disappears, the call follows a remaining
//  Bluetooth or wired device, or else the earpiece. The first device list is the
//  baseline, so devices already there move nothing.
//
//  A new client forgets what was given to the old one. A change the SDK refused
//  is asked for again at the next attach, request, device change or join.
//

import AVFoundation
import ConduitCallEngine

/// An audio route the SmallWebRTC SDK can be asked to prefer.
enum SmallWebRTCAudioRoute: String, CaseIterable, Sendable {
    case earpiece
    case speaker
    case bluetooth
    case wired
}

extension SmallWebRTCAudioRoute {
    /// The route of the session's output port; nil for one the transport leaves to
    /// the SDK (car audio, AirPlay, USB, HDMI and the like).
    init?(outputPort: AVAudioSession.Port) {
        switch outputPort {
        case .builtInReceiver: self = .earpiece
        case .builtInSpeaker: self = .speaker
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: self = .bluetooth
        case .headphones, .headsetMic: self = .wired
        default: return nil
        }
    }

    /// The route of a device id the SDK lists (`earpiece`, `speakerphone`,
    /// `bluetooth`, `wired`), classified as the engine classifies ids.
    init?(deviceID: String) {
        switch AudioRouteKind(deviceID: deviceID) {
        case .receiver: self = .earpiece
        case .speaker: self = .speaker
        case .bluetooth: self = .bluetooth
        case .wired: self = .wired
        case .other: return nil
        }
    }

    /// The SDK's id for the route (its `AudioDeviceType` raw value).
    var deviceID: String {
        switch self {
        case .earpiece: "earpiece"
        case .speaker: "speakerphone"
        case .bluetooth: "bluetooth"
        case .wired: "wired"
        }
    }
}

struct SmallWebRTCAudioRouteGate {
    /// One change to give the SDK, tagged with the client it was decided for. A nil
    /// route clears the client's preferred device, leaving the SDK's own choice.
    struct Application: Equatable {
        let route: SmallWebRTCAudioRoute?
        let session: Int
    }

    /// What the engine asked for (`setAudioDevice`); wins over the followed route.
    private(set) var requested: SmallWebRTCAudioRoute?
    /// The route the transport keeps the call on while the engine has asked for none.
    private(set) var followed: SmallWebRTCAudioRoute?
    private(set) var hasAttached = false
    /// `followed` was read at a join before the first attach.
    private(set) var isFollowedRouteProvisional = false
    /// The routes in the SDK's last non-empty device list; empty until one arrives.
    private(set) var knownDevices: Set<SmallWebRTCAudioRoute> = []
    /// What the current client was given; `nil` for nothing (a new client) or a
    /// cleared preference.
    private(set) var applied: SmallWebRTCAudioRoute?
    /// The SDK refused the last change, so what the client prefers is not known.
    private(set) var isAppliedUnknown = false
    private(set) var session = 0

    /// The route the SDK should prefer now; `nil` leaves the SDK's own choice.
    var wanted: SmallWebRTCAudioRoute? { requested ?? followed }

    /// Why `wanted` is what it is, for logs.
    var wantedReason: String {
        if requested != nil { return "engine request" }
        if followed == nil { return "no route known" }
        return isFollowedRouteProvisional ? "the call's route before activation" : "the call's route"
    }

    /// A join is about to start. With no route known yet (no attach, no request),
    /// takes `activeRoute`, the session's route now, as a provisional one.
    mutating func joinWillStart(activeRoute: SmallWebRTCAudioRoute?) {
        guard !hasAttached, requested == nil, followed == nil, let activeRoute else { return }
        followed = activeRoute == .speaker ? .earpiece : activeRoute
        isFollowedRouteProvisional = true
    }

    /// CallKit activated the session (or a hold ended). The first attach takes
    /// `activeRoute`, the route the session is on now, as the route to keep, and
    /// `devices` as the baseline if no device list came before. Returns whether it
    /// was the first attach.
    @discardableResult
    mutating func attach(activeRoute: SmallWebRTCAudioRoute?, devices: Set<SmallWebRTCAudioRoute>) -> Bool {
        guard !hasAttached else { return false }
        hasAttached = true
        followed = activeRoute
        isFollowedRouteProvisional = false
        if knownDevices.isEmpty { knownDevices = devices }
        return true
    }

    /// The engine asked for `route`, the speaker default or the user's pick.
    mutating func engineDidRequest(_ route: SmallWebRTCAudioRoute) {
        requested = route
    }

    /// The SDK reported its device list. An empty list says nothing and is ignored.
    mutating func devicesDidChange(_ devices: Set<SmallWebRTCAudioRoute>) {
        guard !devices.isEmpty else { return }
        let previous = knownDevices
        knownDevices = devices
        guard !previous.isEmpty, requested == nil, let current = followed else { return }
        let externals: [SmallWebRTCAudioRoute] = [.bluetooth, .wired]
        let appeared = devices.subtracting(previous)
        if let external = externals.first(where: appeared.contains) {
            followed = external
        } else if previous.contains(current), !devices.contains(current) {
            followed = externals.first(where: devices.contains)
                ?? (devices.contains(.earpiece) ? .earpiece : .speaker)
        }
    }

    /// The transport made a new client, which has been given nothing.
    mutating func sessionDidReset() {
        session += 1
        applied = nil
        isAppliedUnknown = false
    }

    /// The next change to give the SDK, counted as given; `nil` if there is none.
    /// A route no longer wanted (the first attach found one the transport cannot
    /// name) is cleared.
    mutating func beginApplying() -> Application? {
        guard isAppliedUnknown || wanted != applied else { return nil }
        applied = wanted
        isAppliedUnknown = false
        return Application(route: wanted, session: session)
    }

    /// The SDK refused `application`: what the client prefers is unknown, so the
    /// next trigger asks again (an attach, a request, a device change, a join).
    mutating func applyDidFail(_ application: Application) {
        guard application.session == session, applied == application.route else { return }
        isAppliedUnknown = true
    }
}
