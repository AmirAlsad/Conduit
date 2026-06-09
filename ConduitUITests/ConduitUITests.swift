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

    /// Swipe-to-delete removes a call from Recents. Launches with a fresh in-memory
    /// store (`--uitest`) seeded with exactly one completed call (`CONDUIT_DEBUG_SEED`),
    /// so deleting it reveals the empty state.
    @MainActor
    func testSwipeToDeleteRemovesRecentCall() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest"]
        app.launchEnvironment["CONDUIT_DEBUG_SEED"] = "1"
        app.launch()

        let row = app.descendants(matching: .any).matching(identifier: "Recents_Row_0").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Seeded recents row should appear")

        row.swipeLeft()
        let deleteButton = app.buttons["Recents_DeleteButton_0"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 2), "Delete action should reveal on swipe")
        deleteButton.tap()

        XCTAssertTrue(
            app.staticTexts["No Recent Calls"].waitForExistence(timeout: 5),
            "Deleting the only call should reveal the empty state"
        )
        XCTAssertFalse(row.exists, "Deleted row should be gone")
    }
}
