//
//  ConduitUITests.swift
//  ConduitUITests
//
//  UI tests are pinned to iOS 18.x (see CLAUDE.md / CI). Note: the core of the
//  app — a live CallKit + WebRTC call — cannot run in the simulator and is
//  device-only; these simulator UI tests cover launch and in-app screens only.
//

import XCTest

final class ConduitUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Swipe-to-delete removes exactly the swiped call from Recents. Launches with a
    /// fresh in-memory store (`--uitest`) seeded with several calls
    /// (`CONDUIT_DEBUG_SEED`), so the list stays non-empty afterwards. Rows are keyed
    /// by index, which shifts up after a delete, so the test snapshots every row
    /// (index to label) before and after and expects the "after" list to be the
    /// "before" list minus its first row.
    @MainActor
    func testSwipeToDeleteRemovesRecentCall() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest"]
        app.launchEnvironment["CONDUIT_DEBUG_SEED"] = "1"
        app.launch()

        let first = app.buttons["Recents_Row_0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "Seeded recents row should appear")

        let before = recentRowLabels(in: app)
        XCTAssertGreaterThan(before.count, 1, "Seed should hold several calls so the list survives a delete")

        first.swipeLeft()
        let deleteButton = app.buttons["Recents_DeleteButton_0"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 2), "Delete action should reveal on swipe")
        deleteButton.tap()

        XCTAssertTrue(
            app.buttons["Recents_Row_\(before.count - 1)"].waitForNonExistence(timeout: 5),
            "The list should shrink by one row"
        )
        let after = recentRowLabels(in: app)
        XCTAssertEqual(after, Array(before.dropFirst()), "Only the swiped call should be removed, the rest unchanged and in order")
        XCTAssertFalse(app.staticTexts["No Recent Calls"].exists, "Other calls remain, so no empty state")
    }

    /// Row labels in index order, scrolling the list so rows beyond the first screen are included.
    @MainActor
    private func recentRowLabels(in app: XCUIApplication) -> [String] {
        let list = app.collectionViews["Recents_Screen"]
        for _ in 0..<5 { list.swipeDown() }

        var labels: [Int: String] = [:]
        var previousCount = -1
        while labels.count != previousCount {
            previousCount = labels.count
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'Recents_Row_'"))
            for row in rows.allElementsBoundByIndex where row.exists {
                if let index = Int(row.identifier.dropFirst("Recents_Row_".count)) {
                    labels[index] = row.label
                }
            }
            list.swipeUp()
        }
        for _ in 0..<5 { list.swipeDown() }
        return labels.keys.sorted().map { labels[$0] ?? "" }
    }
}
