//
//  CallEngineConfiguration.swift
//  Conduit
//
//  The host's settings for the call engine. `isPushToTalkEnabled` is a closure so a
//  mid-call settings flip is honoured on the next mic decision.
//

import Foundation

struct CallEngineConfiguration {
    /// The caller name a ring shows when the push carries none.
    var unknownCallerName: String
    var isPushToTalkEnabled: @MainActor () -> Bool

    init(
        unknownCallerName: String = "Unknown",
        isPushToTalkEnabled: @escaping @MainActor () -> Bool = { false }
    ) {
        self.unknownCallerName = unknownCallerName
        self.isPushToTalkEnabled = isPushToTalkEnabled
    }
}
