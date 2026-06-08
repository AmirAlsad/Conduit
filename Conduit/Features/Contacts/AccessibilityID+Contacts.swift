//
//  AccessibilityID+Contacts.swift
//  Conduit
//
//  Identifiers for the Contacts (agents) tab. See AccessibilityID.swift.
//

import Foundation

extension AccessibilityID {
    enum Contacts {
        static let screen = "Contacts_Screen"
        static let addButton = "Contacts_AddButton"
        static let list = "Contacts_List"
        static func row(_ index: Int) -> String { "Contacts_Row_\(index)" }
        static func callButton(_ index: Int) -> String { "Contacts_CallButton_\(index)" }
    }
}
