//
//  AudioRouteKind+Display.swift
//  Conduit
//
//  How the in-call route picker shows each audio route: its label, icon, and
//  order (iPhone, Speaker, then external routes).
//

import Foundation

extension AudioRouteKind {
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
