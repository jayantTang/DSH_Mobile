#if DEBUG
import Foundation
import XCTest

@testable import DSHKit

/// DEBUG 取数探针的编码/落盘（不连网、不发请求）。
final class FoldPerfProbeTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fold-probe-tests-\(UUID().uuidString)")
            .appendingPathComponent("dsh-fold-probe.json")
    }

    func test_counts_are_per_call_site_and_the_schema_has_the_required_fields() throws {
        var report = FoldPerfProbe.Report(launchId: "L1", startedAt: 123)
        report.recordRequest(.summaryFirst)
        report.recordRequest(.summaryFirst)
        report.recordRequest(.stepBody)
        XCTAssertEqual(report.count(.summaryFirst), 2)
        XCTAssertEqual(report.count(.summaryOlder), 0)

        let index = report.append(FoldPerfProbe.Sample(
            kind: .summaryFirst, fold: "summary", limit: 12, maxBytes: 262_144,
            parseMs: 9.5, requestMs: 12.5, frameMs: 18, records: 10, bytes: 5000))
        report.updateSample(at: index, visibleMs: 22)
        report.recordFailure("summary.first: boom")

        let data = report.encoded()
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["launchId"] as? String, "L1")
        XCTAssertEqual(object["startedAt"] as? Double, 123)
        let counts = try XCTUnwrap(object["counts"] as? [String: Any])
        XCTAssertEqual(counts["summary.first"] as? Int, 2)
        XCTAssertEqual(counts["step.body"] as? Int, 1)
        XCTAssertEqual(object["lastError"] as? String, "summary.first: boom")
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        let first = try XCTUnwrap(samples.first)
        XCTAssertEqual(first["kind"] as? String, "summary.first")
        XCTAssertEqual(first["fold"] as? String, "summary")
        XCTAssertEqual(first["limit"] as? Int, 12)
        XCTAssertEqual(first["maxBytes"] as? Int, 262_144)
        XCTAssertEqual(first["parseMs"] as? Double, 9.5)
        XCTAssertEqual(first["requestMs"] as? Double, 12.5)
        XCTAssertEqual(first["frameMs"] as? Double, 18)
        XCTAssertEqual(first["visibleMs"] as? Double, 22)
        XCTAssertEqual(first["records"] as? Int, 10)
        XCTAssertEqual(first["bytes"] as? Int, 5000)
    }

    func test_the_kind_strings_are_the_ones_the_test_engineer_reads() {
        XCTAssertEqual(FoldPerfProbe.Kind.summaryFirst.rawValue, "summary.first")
        XCTAssertEqual(FoldPerfProbe.Kind.summaryOlder.rawValue, "summary.older")
        XCTAssertEqual(FoldPerfProbe.Kind.stepBody.rawValue, "step.body")
        XCTAssertEqual(FoldPerfProbe.Kind.summaryPage.rawValue, "summary.page")
        XCTAssertEqual(FoldPerfProbe.Kind.legacyV1.rawValue, "legacy.v1")
        XCTAssertEqual(FoldPerfProbe.Kind.historyNone.rawValue, "history.none")
    }

    func test_the_report_is_trimmed_to_the_file_budget_without_losing_counts() throws {
        var report = FoldPerfProbe.Report(launchId: "L2", startedAt: 0)
        report.recordRequest(.historyNone)
        for index in 0..<600 {
            report.append(FoldPerfProbe.Sample(kind: .historyNone,
                                                requestMs: Double(index),
                                                records: 200, bytes: 4096))
        }
        let oldLimit = FoldPerfProbe.maxFileBytes
        FoldPerfProbe.maxFileBytes = 8 * 1024
        defer { FoldPerfProbe.maxFileBytes = oldLimit }

        let data = report.encoded()
        XCTAssertLessThanOrEqual(data.count, 8 * 1024, "探针文件必须 <64KB（测试压到 8KB）")
        let decoded = try FoldPerfProbe.Report.decode(data)
        XCTAssertEqual(decoded.count(.historyNone), 1, "计数不能丢")
        XCTAssertFalse(decoded.samples.isEmpty)
        XCTAssertLessThan(decoded.samples.count, 600)
    }

    func test_writing_is_atomic_and_overwrites_previous_content() throws {
        let url = tempURL()
        var report = FoldPerfProbe.Report(launchId: "L3", startedAt: 7)
        report.recordRequest(.summaryOlder)
        try FoldPerfProbe.write(report, to: url)
        XCTAssertEqual(try FoldPerfProbe.read(from: url).launchId, "L3")

        report.lastError = "second write"
        try FoldPerfProbe.write(report, to: url)
        let readBack = try FoldPerfProbe.read(from: url)
        XCTAssertEqual(readBack.lastError, "second write")
        XCTAssertEqual(readBack.count(.summaryOlder), 1)

        // 目录里只留目标文件（原子写不会留下半个 JSON 或临时文件）。
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["dsh-fold-probe.json"])
    }

    func test_the_file_lives_under_library_caches() {
        XCTAssertTrue(FoldPerfProbe.fileURL.path.hasSuffix("Library/Caches/dsh-fold-probe.json"),
                      FoldPerfProbe.fileURL.path)
    }

    func test_payload_bytes_are_not_computed_when_the_probe_is_off() throws {
        // 本测试进程没有 `-DSHFoldPerfProbe`：关闭时连编码都不做。
        XCTAssertFalse(FoldPerfProbe.isEnabled)
        let record = SessionRecord(event: try JSONDecoder().decode(
            SessionEvent.self,
            from: Data(#"{"type":"user/message","seq":1,"data":{}}"#.utf8)))
        XCTAssertNil(FoldPerfProbe.payloadBytes([record]))
    }
}
#endif
