import XCTest

/// Grants the system notification permission for the already-installed app.
/// This target has no app dependency, so it does not replace the OTA build
/// under test; it only installs a test runner and drives the app by bundle id.
final class NotificationPermissionTests: XCTestCase {
    func testGrantNotificationPermission() {
        let app = XCUIApplication(bundleIdentifier: "com.jayanttang.dsh")
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            if alert.buttons["允许"].exists {
                alert.buttons["允许"].tap()
            } else if alert.buttons["Allow"].exists {
                alert.buttons["Allow"].tap()
            } else if alert.buttons.allElementsBoundByIndex.count > 1 {
                alert.buttons.allElementsBoundByIndex.last?.tap()
            }
        }
        Thread.sleep(forTimeInterval: 8)
    }
}
