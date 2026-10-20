import XCTest
@testable import DSHKit

/// 锚点位移口径：三个 UIKit 方法共用这一份，改动必须在这里先红。
final class TranscriptScrollAdjustmentTests: XCTestCase {

    func testDeltaIsAfterMinusBefore() {
        XCTAssertEqual(TranscriptScrollAdjustment.delta(anchorBefore: 100, anchorAfter: 160), 60)
        XCTAssertEqual(TranscriptScrollAdjustment.delta(anchorBefore: 100, anchorAfter: 40), -60)
    }

    func testMissingAnchorProducesNoMovementForThatSide() {
        XCTAssertEqual(TranscriptScrollAdjustment.delta(anchorBefore: 120, anchorAfter: nil), -120)
        XCTAssertEqual(TranscriptScrollAdjustment.delta(anchorBefore: nil, anchorAfter: 120), 120)
        XCTAssertEqual(TranscriptScrollAdjustment.delta(anchorBefore: nil, anchorAfter: nil), 0)
    }

    func testResidualOnlyReturnsBeyondTolerance() {
        XCTAssertEqual(
            TranscriptScrollAdjustment.residual(
                anchorBefore: 100, anchorAfterCorrection: 100.4, tolerance: 0.5),
            0)
        XCTAssertEqual(
            TranscriptScrollAdjustment.residual(
                anchorBefore: 100, anchorAfterCorrection: 102, tolerance: 0.5),
            2)
        // 修正后锚点丢了：残差按 0 算，不能把整段 before 当成位移再加一次。
        XCTAssertEqual(
            TranscriptScrollAdjustment.residual(
                anchorBefore: 100, anchorAfterCorrection: nil, tolerance: 0.5),
            0)
    }
}
