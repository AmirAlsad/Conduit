//
//  AccessibilityID+Debug.swift
//  Conduit
//
//  Identifiers for the DEBUG-only engine-connect screen.
//

#if DEBUG
import Foundation

extension AccessibilityID {
    enum Debug {
        static let dailyConnectLink = "Debug_DailyConnectLink"
        static let baseURLField = "Debug_BaseURLField"
        static let apiKeyField = "Debug_ApiKeyField"
        static let agentPicker = "Debug_AgentPicker"
        static let connectButton = "Debug_ConnectButton"
        static let disconnectButton = "Debug_DisconnectButton"
        static let stateLabel = "Debug_StateLabel"
    }
}
#endif
