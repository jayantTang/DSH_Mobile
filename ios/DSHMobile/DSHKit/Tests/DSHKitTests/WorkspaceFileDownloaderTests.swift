import Foundation
import XCTest

@testable import DSHKit

/// The download loop's contract is "advance by what arrived, stop on `eof`".
///
/// It exists because the Host clamps a `readBytes` window to its own `maxBytes`
/// (2 MiB in this deployment) no matter what the caller asks for. A loop that
/// trusted its requested size — or that stopped after one window — would hand
/// back a truncated document that looks complete, so the clamp is reproduced
/// here rather than mocked away.
final class WorkspaceFileDownloaderTests: XCTestCase {

    /// Serves `stat` and `readBytes` from an in-memory body, clamping windows the
    /// way the Host does and recording every call.
    private final class Host: DSHCarrier, @unchecked Sendable {
        struct Call { let method: String; let args: [String: Any] }

        private let lock = NSLock()
        private(set) var calls: [Call] = []

        var body: Data
        /// What `stat` reports; defaults to the body's real size.
        var reportedBytes: Int?
        /// Answer every window with an empty `data` and `eof: false`.
        var stalls = false
        /// The clamp the Host applies to a requested window.
        var clamp = WorkspaceFileDownloader.windowBytes

        init(body: Data) {
            self.body = body
        }

        /// Offsets each window was asked for, in order, when a test wants to
        /// prove that a retry repeated one instead of skipping ahead.
        var requestedOffsets: [Int] {
            lock.withLock {
                calls.filter { $0.method == "workspaceFiles/readBytes" }
                    .compactMap { ($0.args["range"] as? [String: Any])?["offset"] as? Int }
            }
        }

        /// Fail the first `n` attempts at a given offset, the way a stalled
        /// socket or a dropped relay does.
        var failuresBeforeSuccess = 0
        private var failuresServed = 0

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String,
            args: Args,
            as valueType: Value.Type
        ) async throws -> Value {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(args))
            let object = encoded as? [String: Any] ?? [:]
            lock.withLock { calls.append(Call(method: method, args: object)) }

            switch method {
            case "workspaceFiles/stat":
                let size = reportedBytes ?? body.count
                return try Self.decode(Value.self, """
                {"absolutePath":"/w/report.pdf","version":"v1","bytes":\(size)}
                """)

            case "workspaceFiles/readBytes":
                let served = lock.withLock { () -> Int in
                    defer { failuresServed += 1 }
                    return failuresServed
                }
                if served < failuresBeforeSuccess {
                    throw DSHTransportError.timedOut(method: method)
                }
                guard !stalls else {
                    return try Self.decode(Value.self, #"{"offset":0,"data":"","eof":false}"#)
                }
                let range = object["range"] as? [String: Any] ?? [:]
                let offset = range["offset"] as? Int ?? 0
                // `length`, not `limit`: the Host ignores a field it does not
                // know, and refuses a window over its cap rather than trimming it.
                let requested = range["length"] as? Int ?? clamp
                guard requested <= clamp else {
                    throw DSHRPCFailure(
                        code: "workspace-file/too-large",
                        message: "\(requested) bytes exceed the \(clamp) byte cap"
                    )
                }
                let start = min(offset, body.count)
                let end = min(start + requested, body.count)
                let piece = body.subdata(in: start..<end)
                let eof = end >= body.count
                return try Self.decode(Value.self, """
                {"offset":\(offset),"data":"\(piece.base64EncodedString())","eof":\(eof),\
                "bytes":\(reportedBytes ?? body.count),"version":"v1"}
                """)

            default:
                return try Self.decode(Value.self, "{}")
            }
        }

        func stream<Args: Encodable & Sendable>(
            endpoint: String,
            args: Args
        ) async -> AsyncThrowingStream<JSONValue, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func eventResult(_ result: JSONValue) async throws {}
        func close() async {}

        private static func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
            try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        }
    }

    private func downloader(_ host: Host, retries: Int = 2) -> WorkspaceFileDownloader {
        // No backoff sleeps in tests: the schedule is the transport's problem,
        // what matters here is that the same offset is asked again.
        WorkspaceFileDownloader(
            client: DSHClient(carrier: host),
            pacing: .zero,
            retries: retries,
            backoff: { _ in .zero }
        )
    }

    /// Progress arrives on the download's own executor, so the test collects it
    /// behind a lock rather than in a captured `var`.
    private final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []

        func append(_ value: Int) { lock.withLock { values.append(value) } }
        var all: [Int] { lock.withLock { values } }
    }

    private func temporaryFile(_ name: String = "report.pdf") -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-downloader-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return directory.appendingPathComponent(name)
    }

    /// Bytes that are not text and not a whole number of windows, so an off-by-one
    /// or a UTF-8 round trip cannot pass unnoticed.
    private func body(bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(($0 &* 31 &+ 7) % 251) })
    }

    func testFetchPagesByReceivedBytesAndStopsOnEOF() async throws {
        // 2.5 windows: the host clamps the second request, so the loop can only
        // finish if it advances by `received` rather than by `windowBytes`.
        let content = body(bytes: WorkspaceFileDownloader.windowBytes * 2 + 12345)
        let host = Host(body: content)
        let destination = temporaryFile()

        let progress = Recorded()
        let fetched = try await downloader(host).fetch(
            scopeId: "session-1",
            path: "report.pdf",
            to: destination,
            onProgress: { progress.append($0.received) }
        )

        XCTAssertEqual(fetched.bytes, content.count)
        XCTAssertEqual(fetched.version, "v1")
        XCTAssertEqual(try Data(contentsOf: destination), content, "assembled bytes differ")
        XCTAssertEqual(progress.all.last, content.count)
        XCTAssertEqual(progress.all, progress.all.sorted(), "progress must not go backwards")

        let reads = host.calls.filter { $0.method == "workspaceFiles/readBytes" }
        XCTAssertEqual(reads.count, 3, "one call per window")
        let offsets = reads.map { ($0.args["range"] as? [String: Any])?["offset"] as? Int }
        XCTAssertEqual(offsets, [0, WorkspaceFileDownloader.windowBytes, WorkspaceFileDownloader.windowBytes * 2])
        XCTAssertTrue(
            reads.allSatisfy { (($0.args["range"] as? [String: Any])?["length"] as? Int) == WorkspaceFileDownloader.windowBytes },
            "every window asks for exactly the deployment cap"
        )
    }

    func testAFileThatDoesNotAddUpIsNotHandedBackAsComplete() async throws {
        let host = Host(body: body(bytes: 4096))
        // The host claims a size the stream never reaches: the kind of answer a
        // file being rewritten underneath the download produces.
        host.reportedBytes = 9000
        let destination = temporaryFile()

        do {
            _ = try await downloader(host).fetch(scopeId: "s", path: "report.pdf", to: destination)
            XCTFail("a short file must not be handed back as complete")
        } catch let failure as WorkspaceFileDownloader.Failure {
            XCTAssertEqual(failure, .sizeMismatch(expected: 9000, received: 4096))
            XCTAssertFalse(failure.isResumable, "a size that disagrees is not worth resuming")
        }
        // The bytes stay on disk: only the caller can decide to throw them away.
        XCTAssertEqual(try Data(contentsOf: destination).count, 4096)
    }

    func testAnEmptyWindowWithoutEOFIsRetriedThenGivenUpOn() async throws {
        let host = Host(body: body(bytes: 2048))
        host.stalls = true
        let destination = temporaryFile()

        do {
            _ = try await downloader(host, retries: 2).fetch(scopeId: "s", path: "report.pdf", to: destination)
            XCTFail("an empty window without eof must not spin forever")
        } catch let failure as WorkspaceFileDownloader.Failure {
            guard case .interrupted(let offset, let saved, let reason) = failure else {
                return XCTFail("expected an interrupted transfer, got \(failure)")
            }
            XCTAssertEqual(offset, 0)
            XCTAssertEqual(saved, 0)
            XCTAssertTrue(reason.contains("没有返回更多内容"), reason)
            XCTAssertTrue(failure.isResumable)
        }
        // Three attempts: the first plus two retries, all at the same offset.
        XCTAssertEqual(host.requestedOffsets, [0, 0, 0])
    }

    func testATransientFailureIsRetriedAtTheSameOffset() async throws {
        // Two windows refuse before answering: the download must not lose the
        // first window's bytes, and must ask for the same offset again.
        let content = body(bytes: 300_000)
        let host = Host(body: content)
        host.failuresBeforeSuccess = 2
        let destination = temporaryFile()

        let fetched = try await downloader(host, retries: 3).fetch(
            scopeId: "s", path: "clip.mp4", to: destination
        )

        XCTAssertEqual(try Data(contentsOf: destination), content)
        XCTAssertEqual(fetched.bytes, content.count)
        XCTAssertEqual(host.requestedOffsets, [0, 0, 0], "a failed window is asked again, not skipped")
    }

    func testResumeContinuesFromWhatIsAlreadyOnDisk() async throws {
        let content = body(bytes: 500_000)
        let host = Host(body: content)
        let destination = temporaryFile()
        let downloader = downloader(host)

        // Half the file arrives, then the link dies for good.
        host.failuresBeforeSuccess = 0
        let firstHalf = 200_000
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = FileHandle(forWritingAtPath: destination.path)!
        try handle.write(contentsOf: content.prefix(firstHalf))
        try handle.close()

        let fetched = try await downloader.fetch(
            scopeId: "s", path: "clip.mp4", to: destination, from: firstHalf
        )

        XCTAssertEqual(try Data(contentsOf: destination), content, "resume must not corrupt the prefix")
        XCTAssertEqual(fetched.bytes, content.count)
        XCTAssertEqual(host.requestedOffsets.first, firstHalf, "the first request is the resume offset")
    }

    func testCancellationKeepsWhatArrivedSoItCanResume() async throws {
        // Big enough that the fetch is still running when the task is cancelled.
        let host = Host(body: body(bytes: WorkspaceFileDownloader.windowBytes * 40))
        let destination = temporaryFile()
        let downloader = downloader(host)

        let task = Task {
            try await downloader.fetch(scopeId: "s", path: "report.pdf", to: destination)
        }
        // Cancel once at least one window has landed, so this exercises the loop
        // rather than a task that never started.
        while host.calls.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled download must not report success")
        } catch is CancellationError {
            // Expected.
        }
        // Whatever arrived stays: cancelling is how a person pauses a download,
        // and resuming it must not start from zero.
        let saved = (try? Data(contentsOf: destination).count) ?? 0
        XCTAssertGreaterThan(saved, 0)
        XCTAssertLessThan(saved, WorkspaceFileDownloader.windowBytes * 40, "cancelled early")
    }

    func testAWindowOverADeploymentsCapShrinksInsteadOfFailing() async throws {
        // A host configured with a smaller `maxBytes` refuses the window this
        // build asks for; the download must still finish, at the cap it has.
        let content = body(bytes: 900_000)
        let host = Host(body: content)
        host.clamp = 1024 * 1024
        let destination = temporaryFile()

        let fetched = try await downloader(host).fetch(
            scopeId: "s", path: "big.pdf", to: destination
        )

        XCTAssertEqual(try Data(contentsOf: destination), content)
        XCTAssertEqual(fetched.bytes, content.count)

        let requested = host.calls
            .filter { $0.method == "workspaceFiles/readBytes" }
            .compactMap { ($0.args["range"] as? [String: Any])?["length"] as? Int }
        XCTAssertEqual(requested.prefix(2), [WorkspaceFileDownloader.windowBytes, 1024 * 1024],
                       "the refusal must be answered by halving")
        XCTAssertEqual(requested.last, 1024 * 1024, "the accepted window is the deployment's cap")
    }

    func testDataRefusesAFileOverTheCapWithoutReadingIt() async throws {        let host = Host(body: body(bytes: 3 * 1024 * 1024))
        let downloader = downloader(host)

        do {
            _ = try await downloader.data(scopeId: "s", path: "shot.png", cap: 1024 * 1024)
            XCTFail("a file over the cap must be refused")
        } catch let failure as WorkspaceFileDownloader.Failure {
            XCTAssertEqual(failure, .overCap(limit: 1024 * 1024, bytes: 3 * 1024 * 1024))
        }
        XCTAssertTrue(
            host.calls.allSatisfy { $0.method == "workspaceFiles/stat" },
            "the size alone decides; no bytes should have moved"
        )
    }

    func testDataAssemblesAWholeFile() async throws {
        let content = body(bytes: 700_000)
        let host = Host(body: content)

        let data = try await downloader(host).data(scopeId: "s", path: "shot.png", cap: 1024 * 1024)

        XCTAssertEqual(data, content)
    }
}
