import XCTest

/// SR-02.10: the HTML preview surface renders a local report in the simulator.
final class WorkspaceHTMLPreviewTests: XCTestCase {
    func testRenderedPreviewIsPresent() {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/test-report-fixture.html")
        let app = XCUIApplication()
        app.launchArguments = ["-DSHHTMLPreview", fixture.path]
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20),
                      "HTML preview web view missing")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "html-preview"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
