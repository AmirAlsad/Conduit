//
//  AccessibilityID+AddAgent.swift
//  Conduit
//
//  Identifiers for the add/edit-agent sheet. See AccessibilityID.swift.
//

import Foundation

extension AccessibilityID {
    enum AddAgent {
        static let screen = "AddAgent_Screen"
        static let nameField = "AddAgent_NameField"
        static let detailField = "AddAgent_DetailField"
        static let transportPicker = "AddAgent_TransportPicker"
        static let urlField = "AddAgent_URLField"
        static let tokenField = "AddAgent_TokenField"
        static let pairingField = "AddAgent_PairingField"
        static let testConnectionButton = "AddAgent_TestConnectionButton"
        static let testResult = "AddAgent_TestResult"
        static let saveButton = "AddAgent_SaveButton"
        static let cancelButton = "AddAgent_CancelButton"
    }
}
