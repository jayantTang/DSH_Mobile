import XCTest

/// Physical-device baseline for the session-list journey.
///
/// The signpost is emitted by `SessionListModel.start`; measuring it here keeps
/// app-launch automation out of the reported interval. Run this only on a
/// physical destination: simulator numbers are functional evidence, not a
/// performance baseline.
final class PerformanceBaselineTests: XCTestCase {
    func testSessionListFirstContent() {
        let app = XCUIApplication()
        measure(metrics: [
            XCTOSSignpostMetric(subsystem: "com.jayanttang.dsh",
                                category: "performance",
                                name: "session.first-content"),
        ]) {
            app.launch()
        }
    }

    /// Read-only file preview. Uses the debug launch hook so no UI gesture or
    /// owner session is involved; the file lives in the repository fixture tree.
    func testFileFirstPage() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-DSHOpenFile", "ios/DSHMobile/DSHMobileUITests/Fixtures/long-line.txt",
        ]
        measure(metrics: [
            XCTOSSignpostMetric(subsystem: "com.jayanttang.dsh",
                                category: "performance",
                                name: "file.first-page"),
        ]) {
            app.launch()
        }
    }
}
