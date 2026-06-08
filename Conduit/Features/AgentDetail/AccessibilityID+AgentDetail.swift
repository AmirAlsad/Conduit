//
//  AccessibilityID+AgentDetail.swift
//  Conduit
//
//  Identifiers for the agent detail screen. See AccessibilityID.swift.
//

import Foundation

extension AccessibilityID {
    enum AgentDetail {
        static let screen = "AgentDetail_Screen"
        static let callButton = "AgentDetail_CallButton"
        static let editButton = "AgentDetail_EditButton"
        static let addToContactsButton = "AgentDetail_AddToContactsButton"
        static let deleteButton = "AgentDetail_DeleteButton"
        static let log = "AgentDetail_Log"
        static func logRow(_ index: Int) -> String { "AgentDetail_LogRow_\(index)" }
    }
}
