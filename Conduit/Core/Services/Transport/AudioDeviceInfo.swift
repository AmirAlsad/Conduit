//
//  AudioDeviceInfo.swift
//  Conduit
//
//  A selectable in-call audio route (speaker, earpiece, Bluetooth/AirPods, wired),
//  surfaced by the transport. SDK-agnostic: the Daily adapter maps its device list
//  into these so the in-call route picker never sees an SDK type.
//

import Foundation

struct AudioDeviceInfo: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}
