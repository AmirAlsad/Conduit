//
//  AccessibilityID+Recents.swift
//  Conduit
//
//  Identifiers for the Recents (call log) tab. See AccessibilityID.swift.
//

import Foundation

extension AccessibilityID {
    enum Recents {
        static let screen = "Recents_Screen"
        static let list = "Recents_List"
        static let addButton = "Recents_AddButton"
        static func row(_ index: Int) -> String { "Recents_Row_\(index)" }
        static func infoButton(_ index: Int) -> String { "Recents_InfoButton_\(index)" }
    }
}
