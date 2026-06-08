//
//  AudioRouteDisplay.swift
//  Conduit
//
//  Friendly name + SF Symbol + sort order for an audio route. The transport hands
//  back raw device names (e.g. "Built-in Speaker and Mic", "Built-in Earpiece in
//  Mic"); this maps them to the comfortable labels and icons the in-call route
//  menu shows.
//

import Foundation

enum AudioRouteDisplay {
    static func name(for raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("speaker") { return "Speaker" }
        if lowered.contains("earpiece") || lowered.contains("receiver") { return "iPhone" }
        if lowered.contains("wired") || lowered.contains("headphone") { return "Headphones" }
        if lowered.contains("bluetooth") { return "Bluetooth" }
        return raw // an already-named device, e.g. "AirPods Pro"
    }

    static func icon(for raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("speaker") { return "speaker.wave.2.fill" }
        if lowered.contains("earpiece") || lowered.contains("receiver") { return "iphone" }
        if lowered.contains("airpod") { return "airpods" }
        if lowered.contains("wired") || lowered.contains("headphone") { return "headphones" }
        if lowered.contains("bluetooth") { return "headphones" }
        return "headphones"
    }

    /// Stable display order: iPhone, Speaker, then external (Bluetooth/wired).
    static func rank(for raw: String) -> Int {
        let lowered = raw.lowercased()
        if lowered.contains("earpiece") || lowered.contains("receiver") { return 0 }
        if lowered.contains("speaker") { return 1 }
        return 2
    }
}
