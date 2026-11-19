import XCTest

final class LaunchTests: XCTestCase {
    func testColdLaunchAndPrivateDeviceGate() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Device invite"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["Start listening"].exists)
        let unlock = app.buttons["Unlock this device"]
        XCTAssertFalse(unlock.isEnabled)
        let link = app.secureTextFields["Invite link"]; link.tap()
        link.typeText("http://example.com")
        unlock.tap()
        XCTAssertTrue(app.staticTexts["Paste the full HTTPS invite link."].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["History"].exists)
    }
}
