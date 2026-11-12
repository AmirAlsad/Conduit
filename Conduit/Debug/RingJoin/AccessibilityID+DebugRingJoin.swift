//
//  AccessibilityID+DebugRingJoin.swift
//  Conduit
//
//  Identifiers for the DEBUG-only Daily ring-join setting. See AccessibilityID.swift.
//

#if DEBUG
import Foundation

extension AccessibilityID {
    enum DebugRingJoin {
        static let picker = "DebugRingJoin_Picker"
    }
}
#endif
