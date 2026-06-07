//
//  AudioSessionActivating.swift
//  Conduit
//
//  Abstraction over the `AVAudioSession` CallKit activates for a call, exposing
//  only the operations the coordinator performs during the activation handshake.
//  The real implementation wraps `AVAudioSession`; the fake lets the
//  route-decision logic be unit-tested without a live session.
//
//  Methods here must only be invoked after CallKit has activated the session
//  (i.e. from `providerDidActivate`).
//

import Foundation

@MainActor
protocol AudioSessionActivating: AnyObject {
    /// Whether an external output (Bluetooth / CarPlay / car) is the current
    /// route, so the coordinator avoids forcing speaker over a connected car.
    var hasExternalAudioRoute: Bool { get }

    /// Force output to the built-in speaker — the hands-free default when no
    /// car/Bluetooth route is present.
    func overrideOutputToSpeaker() throws

    /// Clear any output override, restoring the system-chosen route.
    func clearOutputOverride() throws
}
