//
//  AccessibilityID+DebugInterruptionRecovery.swift
//  Conduit
//
//  Identifiers for the DEBUG-only recovery-after-a-phone-call settings. See
//  AccessibilityID.swift.
//

#if DEBUG
import Foundation

extension AccessibilityID {
    enum DebugInterruptionRecovery {
        static let sessionPicker = "DebugInterruptionRecovery_SessionPicker"
        static let liveKitPicker = "DebugInterruptionRecovery_LiveKitPicker"
        static let dailyPicker = "DebugInterruptionRecovery_DailyPicker"
    }
}
#endif
