import XCTest

@testable import DSHKit

/// 传输速率算法的用例（spec 023 / S3d，T042）。
///
/// 这段计算原来在 `WorkspaceFilesModel` 里、一条测试都没有，而它的边界值直接决定界面上的数字：
/// 采样太短会算出"200 MB/s"的假尖峰，字节没增长（重传/乱序）会算出负数。
final class TransferSpeedTests: XCTestCase {

    private func sample(_ at: TimeInterval, _ bytes: Int) -> TransferSpeed.Sample {
        TransferSpeed.Sample(at: at, bytes: bytes)
    }

    // MARK: - 瞬时

    func testInstantRateOverASecondIsOneMegabytePerSecond() {
        // 1 秒收到 1 MiB → 1 MB/s（除数就是 1_048_576）。
        let rate = TransferSpeed.instant(previous: sample(0, 0), current: sample(1, 1_048_576))
        XCTAssertEqual(rate ?? 0, 1.0, accuracy: 1e-9)
    }

    func testTooShortSamplesAreIgnored() {
        // 0.1 秒（< 0.15）：算出来会是个尖峰，宁可不报。
        XCTAssertNil(TransferSpeed.instant(previous: sample(0, 0), current: sample(0.1, 10_000_000)))
        // 正好等于阈值也**不算**：口径是严格大于（照搬 App 原来的 `guard seconds > 0.15`）。
        XCTAssertNil(TransferSpeed.instant(previous: sample(0, 0),
                                          current: sample(TransferSpeed.minimumSampleSeconds, 1_048_576)))
        // 比阈值长一点点就算。
        XCTAssertNotNil(TransferSpeed.instant(previous: sample(0, 0),
                                             current: sample(TransferSpeed.minimumSampleSeconds + 0.01, 1_048_576)))
    }

    func testNonGrowingSamplesAreIgnored() {
        // 重传 / 乱序 / 计数回退：不许报负数，也不许报 0 —— 调用方保留上一次的值。
        XCTAssertNil(TransferSpeed.instant(previous: sample(0, 500), current: sample(1, 500)))
        XCTAssertNil(TransferSpeed.instant(previous: sample(0, 500), current: sample(1, 100)))
    }

    func testZeroElapsedIsIgnored() {
        XCTAssertNil(TransferSpeed.instant(previous: sample(5, 0), current: sample(5, 1000)))
    }

    // MARK: - 平滑

    func testFirstSampleIsTakenAsIs() {
        XCTAssertEqual(TransferSpeed.smoothed(previous: nil, instant: 8), 8)
    }

    func testSmoothingBlendsHistoryWithTheNewSample() {
        // 0.6 × 老 + 0.4 × 新
        XCTAssertEqual(TransferSpeed.smoothed(previous: 10, instant: 5), 8, accuracy: 1e-9)
        XCTAssertEqual(TransferSpeed.smoothed(previous: 0, instant: 10), 4, accuracy: 1e-9)
    }

    func testSmoothingRepeatedlyConvergesToTheNewValue() {
        var rate = 1.0
        for _ in 0..<40 { rate = TransferSpeed.smoothed(previous: rate, instant: 20) }
        XCTAssertEqual(rate, 20, accuracy: 0.01, "连续同样采样应当收敛到新值")
    }

    // MARK: - 整段平均（续传完成那条路）

    func testAverageOverTheWholeTransfer() {
        // 2 秒收到 4 MiB → 2 MB/s
        XCTAssertEqual(TransferSpeed.average(bytes: 4 * 1_048_576, seconds: 2) ?? 0, 2, accuracy: 1e-9)
    }

    func testAverageIsNilWithoutBytesOrTime() {
        XCTAssertNil(TransferSpeed.average(bytes: 0, seconds: 1))
        XCTAssertNil(TransferSpeed.average(bytes: 100, seconds: 0))
        XCTAssertNil(TransferSpeed.average(bytes: 100, seconds: -1))
    }

    func testConstantsMatchTheValuesShippedInTheApp() {
        // 这两个常数是"照搬"来的，调它们会改变用户看到的数字，所以钉住。
        XCTAssertEqual(TransferSpeed.minimumSampleSeconds, 0.15)
        XCTAssertEqual(TransferSpeed.smoothingWeight, 0.4)
    }
}
