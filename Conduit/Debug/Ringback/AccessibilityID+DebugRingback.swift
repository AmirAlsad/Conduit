//
//  AccessibilityID+DebugRingback.swift
//  Conduit
//
//  Identifiers for the DEBUG-only ringback setting. See AccessibilityID.swift.
//

#if DEBUG
import Foundation

extension AccessibilityID {
    enum DebugRingback {
        static let picker = "DebugRingback_Picker"
    }
}
#endif
