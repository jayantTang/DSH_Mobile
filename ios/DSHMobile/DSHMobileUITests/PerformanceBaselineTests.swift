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


    /// 滚动卡顿用系统自带的 hitch/memory 指标，不用自造帧率采样。
    /// 只在支持 XCTHitchMetric 的系统上运行；仿真器也可跑，但结论以真机为准。
    @available(iOS 26.0, *)
    func testLongTextScrollHitches() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-DSHOpenFile", "ios/DSHMobile/DSHMobileUITests/Fixtures/plain-long.txt",
        ]
        app.launch()
        let toggle = app.buttons["files.wrap.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "file preview did not show")
        toggle.tap()
        let scroll = app.descendants(matching: .any)["files.reader.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "reader scroll view missing")

        measure(metrics: [
            XCTHitchMetric(application: app),
            XCTMemoryMetric(application: app),
        ]) {
            for _ in 0..<3 { scroll.swipeLeft() }
        }
    }
}
