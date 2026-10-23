//
//  UmbraUITests.swift
//  UmbraUITests
//
//  Created by Saumya Patel on 10/20/26.
//

import XCTest

final class UmbraUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    @MainActor
    func testSimulatorRequiresDeviceAndDoesNotInventCount() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["tunnelStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["tunnelStatus"].label.contains("Device required"))
        XCTAssertTrue(app.staticTexts["deviceRequired"].exists)
        XCTAssertFalse(app.buttons["Install experimental configuration"].isEnabled)
        XCTAssertFalse(app.buttons["Disable experiment"].isEnabled)
        XCTAssertTrue(app.staticTexts["blockedToday"].label.contains("Unavailable"))
        app.swipeUp()
        XCTAssertTrue(app.buttons["runDNSProbe"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["runDNSProbe"].isEnabled)
        XCTAssertTrue(app.staticTexts["List, HaGeZi Multi PRO mini"].exists)
        XCTAssertTrue(app.buttons["List license (GPL-3.0)"].exists)
        XCTAssertFalse(app.staticTexts["Running"].exists)
        #else
        throw XCTSkip("Simulator presentation check; does not install or activate a device VPN.")
        #endif
    }
}
