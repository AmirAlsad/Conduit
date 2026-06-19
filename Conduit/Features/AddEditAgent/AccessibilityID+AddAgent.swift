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
        static let photoPicker = "AddAgent_PhotoPicker"
        static func colorSwatch(_ color: AgentColor) -> String { "AddAgent_Color_\(color.rawValue)" }
        static let cropChooseButton = "AddAgent_CropChooseButton"
        static let cropCancelButton = "AddAgent_CropCancelButton"
        static let transportPicker = "AddAgent_TransportPicker"
        static let dailyAudioNotice = "AddAgent_DailyAudioNotice"
        static let urlField = "AddAgent_URLField"
        static let apiKeyField = "AddAgent_ApiKeyField"
        static let directTokenField = "AddAgent_DirectTokenField"
        static let directDisclosure = "AddAgent_DirectDisclosure"
        static let pairingField = "AddAgent_PairingField"
        static let pairingDocsLink = "AddAgent_PairingDocsLink"
        static let inboundDocsLink = "AddAgent_InboundDocsLink"
        static let inboundToggle = "AddAgent_InboundToggle"
        static let inboundURLField = "AddAgent_InboundURLField"
        static let testConnectionButton = "AddAgent_TestConnectionButton"
        static let testResult = "AddAgent_TestResult"
        static func diagnosticRow(_ stage: DiagnosticStage) -> String { "AddAgent_Diag_\(stage.rawValue)" }
        static let saveButton = "AddAgent_SaveButton"
        static let cancelButton = "AddAgent_CancelButton"
    }
}
