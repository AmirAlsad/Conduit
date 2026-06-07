//
//  AccessibilityID+Root.swift
//  Conduit
//
//  Example feature extension demonstrating the AccessibilityID convention.
//  See AccessibilityID.swift for the convention itself.
//

import Foundation

extension AccessibilityID {
    /// Identifiers for the app's root container view.
    enum Root {
        /// The root screen container.
        static let screen = "Root_Screen"
        /// The app title label.
        static let titleLabel = "Root_TitleLabel"
        /// The app tagline label.
        static let taglineLabel = "Root_TaglineLabel"

        /// Identifier for an indexed tab in the (future) root tab bar.
        /// - Parameter index: Zero-based tab position.
        /// - Returns: The element's accessibility identifier.
        static func tab(_ index: Int) -> String { "Root_Tab_\(index)" }
    }
}
