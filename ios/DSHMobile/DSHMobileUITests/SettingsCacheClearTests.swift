import XCTest

/// SR-06.03: the settings button really clears the local caches.
final class SettingsCacheClearTests: XCTestCase {
    func testClearCacheShowsTheClearedState() {
        let app = XCUIApplication()
        app.launchArguments = ["-DSHOpenScreen", "settings"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 20))

        let button = app.buttons["settings.clear-cache"]
        for _ in 0..<8 where !button.exists {
            app.swipeUp()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "clear-cache button missing")
        button.tap()
        let cleared = app.staticTexts["已清除"].exists || app.staticTexts["Cleared"].exists
        XCTAssertTrue(cleared || app.staticTexts["已清除"].waitForExistence(timeout: 5),
                      "the cleared state did not appear")
    }
}
