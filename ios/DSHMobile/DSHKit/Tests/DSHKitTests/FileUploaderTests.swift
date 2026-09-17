import Foundation
import XCTest

@testable import DSHKit

/// The chunking has to be exact: the connector refuses a transfer whose bytes
/// do not add up, so an off-by-one here means a file that silently never lands.
final class FileUploaderTests: XCTestCase {

    /// Records the calls and answers them the way the connector does.
    private final class Recorder: DSHCarrier, @unchecked Sendable {
        struct Call { let method: String; let args: [String: Any] }

        private let lock = NSLock()
        private(set) var calls: [Call] = []
        /// Bytes the connector would have received, per transfer.
        private(set) var assembled: [String: Data] = [:]

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String,
            args: Args,
            as valueType: Value.Type
        ) async throws -> Value {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(args))
            let object = encoded as? [String: Any] ?? [:]
            let transferId = object["transferId"] as? String ?? ""

            let total: Int = lock.withLock {
                calls.append(Call(method: method, args: object))
                if let chunk = object["data"] as? String, let bytes = Data(base64Encoded: chunk) {
                    assembled[transferId, default: Data()].append(bytes)
                }
                return assembled[transferId]?.count ?? 0
            }
            _ = total

            if method == "_link/fileEnd" {
                let bytes = lock.withLock { assembled[transferId]?.count ?? 0 }
                let json = Data("{\"path\":\"/tmp/x\",\"bytes\":\(bytes)}".utf8)
                return try JSONDecoder().decode(Value.self, from: json)
            }
            return try JSONDecoder().decode(Value.self, from: Data("{\"accepted\":true}".utf8))
        }

        func stream<Args: Encodable & Sendable>(
            endpoint: String,
            args: Args
        ) async -> AsyncThrowingStream<JSONValue, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func eventResult(_ result: JSONValue) async throws {}

        func close() async {}
    }

    func testUploadChunksAndReassemblesTheExactBytes() async throws {
        let recorder = Recorder()
        let uploader = FileUploader(carrier: recorder)

        // A size that is not a multiple of the chunk, plus bytes that are not
        // text, so truncation or an encoding mistake cannot pass unnoticed.
        let size = FileUploader.chunkBytes * 2 + 517
        let body = Data((0..<size).map { UInt8($0 % 251) })

        let staged = try await uploader.upload(
            data: body,
            name: "report.pdf",
            sessionId: "session-1",
            transferId: "t-1"
        )

        let calls = recorder.calls
        XCTAssertEqual(calls.first?.method, "_link/fileBegin")
        XCTAssertEqual(calls.last?.method, "_link/fileEnd")
        XCTAssertEqual(calls.filter { $0.method == "_link/fileChunk" }.count, 3, "wrong chunk count")

        XCTAssertEqual(
            recorder.assembled["t-1"],
            body,
            "the bytes that reached the connector differ from the bytes read"
        )
        XCTAssertEqual(staged.bytes, body.count)

        // The name and size ride on the begin call, which is what lets the
        // connector refuse a short transfer at the end.
        let begin = calls[0].args
        XCTAssertEqual(begin["name"] as? String, "report.pdf")
        XCTAssertEqual(begin["bytes"] as? Int, body.count)
        XCTAssertEqual(begin["sessionId"] as? String, "session-1")
    }

    func testChunksAreNumberedFromZeroWithoutGaps() async throws {
        let recorder = Recorder()
        let uploader = FileUploader(carrier: recorder)
        _ = try await uploader.upload(
            data: Data(repeating: 7, count: FileUploader.chunkBytes * 3),
            name: "big.bin",
            sessionId: "s",
            transferId: "t-2"
        )
        let seqs = recorder.calls
            .filter { $0.method == "_link/fileChunk" }
            .compactMap { $0.args["seq"] as? Int }
        XCTAssertEqual(seqs, Array(0..<seqs.count), "chunks arrived out of order or with a gap")
    }

    func testAnEmptyFileStillCompletesATransfer() async throws {
        // Not a useful file, but the connector must not be left holding an
        // open transfer because the begin/end pair never arrived.
        let recorder = Recorder()
        let uploader = FileUploader(carrier: recorder)
        _ = try await uploader.upload(data: Data(), name: "empty.txt", sessionId: "s", transferId: "t-3")
        XCTAssertEqual(recorder.calls.first?.method, "_link/fileBegin")
        XCTAssertEqual(recorder.calls.last?.method, "_link/fileEnd")
    }
}
