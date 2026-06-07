//
//  AccessibilityID.swift
//  Conduit
//
//  Base namespace for accessibility identifiers.
//

import Foundation

/// Centralized accessibility identifiers used by XCUITest page objects and
/// agent-driven UI automation, which query by stable identifier rather than
/// brittle coordinates or label text.
///
/// **Convention.** One `AccessibilityID+<Feature>.swift` file per feature, each
/// extending this `AccessibilityID` namespace with a nested `enum <Feature>`
/// holding `<Feature>_<Element>` string constants in PascalCase:
///
/// - Use `static let` for one-off elements (e.g. `screen`, a specific button).
/// - Use `static func` for indexed or parameterized identifiers (e.g. a row in
///   a list, or an enum-keyed segment).
///
/// ```swift
/// extension AccessibilityID {
///     enum Recents {
///         static let screen = "Recents_Screen"
///         static func callRow(_ index: Int) -> String { "Recents_CallRow_\(index)" }
///     }
/// }
/// ```
///
/// To register a new feature, create its extension file — do not amend this
/// umbrella enum. The `<Feature>_<Element>` naming keeps identifiers
/// collision-free and greppable.
enum AccessibilityID {}
