//
//  DebugRingbackMethod.swift
//  Conduit
//
//  DEBUG-only choice of how the ringback is played, for the device test that
//  compares the two: the system sound (what Release builds play) or an audio
//  player in the app's audio session. Persisted in UserDefaults and read at each
//  ringback's start, so a change applies to the next call placed.
//

#if DEBUG
import Foundation

enum DebugRingbackMethod: String, CaseIterable, Identifiable {
    case systemSound
    case audioPlayer

    static let defaultsKey = "debug.ringbackMethod"

    static func current(in defaults: UserDefaults = .standard) -> DebugRingbackMethod {
        defaults.string(forKey: defaultsKey).flatMap(DebugRingbackMethod.init(rawValue:)) ?? .systemSound
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemSound: "System sound (ringer volume)"
        case .audioPlayer: "Audio player (call volume)"
        }
    }
}
#endif
