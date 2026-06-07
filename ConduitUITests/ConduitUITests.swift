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
}
