//
//  AccessibilityID+InCall.swift
//  Conduit
//
//  Identifiers for the in-call full-screen surface. See AccessibilityID.swift.
//

import Foundation

extension AccessibilityID {
    enum InCall {
        static let screen = "InCall_Screen"
        static let agentName = "InCall_AgentName"
        static let statusLabel = "InCall_StatusLabel"
        static let muteButton = "InCall_MuteButton"
        static let endButton = "InCall_EndButton"
        static let pushToTalkButton = "InCall_PushToTalkButton"
        static let routePicker = "InCall_RoutePicker"
        static let closeButton = "InCall_CloseButton"
    }
}
