//
//  AccessibilityID+Root.swift
//  Conduit
//
//  Identifiers for the app's root shell. See AccessibilityID.swift for the
//  convention itself.
//

import Foundation

extension AccessibilityID {
    /// Identifiers for the root tab shell.
    enum Root {
        /// The root tab container.
        static let screen = "Root_Screen"

        /// Identifier for an indexed tab's root content.
        /// - Parameter index: Zero-based tab position (0 Recents, 1 Contacts, 2 Settings).
        static func tab(_ index: Int) -> String { "Root_Tab_\(index)" }
    }
}
