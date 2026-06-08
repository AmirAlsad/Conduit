//
//  AudioRouteKind.swift
//  Conduit
//
//  A normalized audio route, derived from the transport's device id (Daily uses
//  stable ids — `speakerphone` / `bluetooth` / `earpiece` / `wired` — while its
//  display NAMES are unreliable, e.g. "Bluetooth Speaker & Mic" contains the word
//  "Speaker"). The in-call picker maps each device to a kind for its label, icon,
//  and order; the active route is matched against the live `AVAudioSession` route
//  (see `AudioRouteKind+Port`).
//

import Foundation

enum AudioRouteKind: Equatable, Sendable {
    case receiver
    case speaker
    case bluetooth
    case wired
    case other

    init(deviceID: String) {
        let id = deviceID.lowercased()
        if id.contains("speaker") && !id.contains("bluetooth") {
            self = .speaker
        } else if id.contains("bluetooth") {
            self = .bluetooth
        } else if id.contains("earpiece") || id.contains("receiver") {
            self = .receiver
        } else if id.contains("wired") || id.contains("headphone") {
            self = .wired
        } else {
            self = .other
        }
    }

    var displayName: String {
        switch self {
        case .receiver: "iPhone"
        case .speaker: "Speaker"
        case .bluetooth: "Bluetooth"
        case .wired: "Headphones"
        case .other: "Audio"
        }
    }

    var iconName: String {
        switch self {
        case .receiver: "iphone"
        case .speaker: "speaker.wave.2.fill"
        case .bluetooth: "headphones"
        case .wired: "headphones"
        case .other: "speaker.wave.2"
        }
    }

    /// Display order in the picker: iPhone, Speaker, then external routes.
    var sortRank: Int {
        switch self {
        case .receiver: 0
        case .speaker: 1
        case .bluetooth: 2
        case .wired: 3
        case .other: 4
        }
    }
}
