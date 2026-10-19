import XCTest
@testable import DSHKit

final class FetchMetricsTests: XCTestCase {
    func test_percentiles_use_nearest_rank() {
        XCTAssertNil(FetchMetrics.percentile([], 0.95))
        XCTAssertEqual(FetchMetrics.percentile([10], 0.95), 10)
        XCTAssertEqual(FetchMetrics.percentile([10, 20, 30, 40], 0.5), 20)
        XCTAssertEqual(FetchMetrics.percentile([10, 20, 30, 40], 0.95), 40)
    }

    func test_duplicate_and_failure_rates() {
        var metrics = FetchMetrics()
        metrics.record(.init(firstRowMs: 100, batchMs: 300, pages: 3, duplicatePages: 0))
        metrics.record(.init(firstRowMs: 200, batchMs: 500, pages: 1, duplicatePages: 1, failure: nil))
        metrics.record(.init(firstRowMs: nil, batchMs: 900, pages: 2, failure: "timeout"))
        XCTAssertEqual(metrics.batchP50Ms, 500)
        XCTAssertEqual(metrics.batchP95Ms, 900)
        XCTAssertEqual(metrics.firstRowP95Ms, 200)
        XCTAssertEqual(metrics.duplicateRate, 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.failures["timeout"], 1)
        XCTAssertEqual(metrics.failureRate(last: 50), 1.0 / 3.0, accuracy: 0.0001)
    }

    func test_ring_keeps_capacity() {
        var metrics = FetchMetrics()
        for index in 0..<(FetchMetrics.capacity + 5) {
            metrics.record(.init(firstRowMs: index, batchMs: index, pages: 1))
        }
        XCTAssertEqual(metrics.count, FetchMetrics.capacity)
    }

    func test_summary_fields_are_stable() {
        var metrics = FetchMetrics()
        metrics.record(.init(firstRowMs: 120, batchMs: 300, pages: 3))
        let fields = metrics.summaryFields()
        XCTAssertEqual(fields["samples"], "1")
        XCTAssertEqual(fields["batchP50Ms"], "300")
        XCTAssertEqual(fields["firstRowP95Ms"], "120")
        XCTAssertEqual(fields["duplicateRate"], "0.000")
        XCTAssertEqual(fields["failureRate"], "0.000")
    }
}
