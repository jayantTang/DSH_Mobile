import Foundation
import XCTest

@testable import DSHKit

/// 图片原图变体的线上形状与错误映射（契约 §1.1–1.3 / §2.1）。
///
/// 这些方法由**连接器**自己回答，不经 Host 转发，所以编码出的方法名与 args 就是
/// 双方唯一的契约。用例断言的是线上那一层（方法名、字段、可选字段是否发出），
/// 以及三种"不可用"结局必须与网络失败分开。
final class ImageVariantsWireTests: XCTestCase {

    /// 按方法名回放预置载荷，并记录被调方法。
    private final class Recorder: DSHCarrier, @unchecked Sendable {
        struct Call: Sendable, Equatable {
            let method: String
            let args: JSONValue?
        }

        private let lock = NSLock()
        private var recorded: [Call] = []
        private var payloads: [String: String] = [:]
        private var failures: [String: any Error] = [:]

        var calls: [Call] {
            lock.withLock { recorded }
        }

        func stub(_ method: String, _ json: String) {
            lock.withLock { payloads[method] = json }
        }

        func fail(_ method: String, with error: any Error) {
            lock.withLock { failures[method] = error }
        }

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String,
            args: Args,
            as valueType: Value.Type
        ) async throws -> Value {
            let encoded = try JSONEncoder().encode(args)
            let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
            let (payload, failure) = lock.withLock { () -> (String?, (any Error)?) in
                recorded.append(Call(method: method, args: value))
                return (payloads[method], failures[method])
            }
            if let failure { throw failure }
            guard let payload else {
                throw NSError(domain: "Recorder", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no stub for \(method)"])
            }
            return try JSONDecoder().decode(Value.self, from: Data(payload.utf8))
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

    // MARK: - commit

    func testCommitSendsTheStagedPathsAndTheCompatibilityFlag() async throws {
        let recorder = Recorder()
        recorder.stub("_link/imageCommit", """
        {"preview":{"receiptId":"rcpt-preview","image":{"attachmentId":"sha256:preview","mediaType":"image/jpeg","bytes":4096,"width":1024,"height":768,"name":"a.jpg"}},
         "original":{"attachmentId":"sha256:original","name":"a.heic","bytes":123456,"mediaType":"image/heic"},
         "originalReason":"tooLarge"}
        """)
        let client = DSHClient(carrier: recorder)

        let value = try await client.commitImage(
            sessionId: "s-1",
            preview: ImageVariantUpload(path: "/dsh/inbox/s-1/p.jpg",
                                        mediaType: "image/jpeg", name: "a.jpg"),
            original: ImageVariantUpload(path: "/dsh/inbox/s-1/o.heic",
                                         mediaType: "image/heic", name: "a.heic"),
            sendOriginalAsFile: true
        )

        let call = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(call.method, "_link/imageCommit")
        XCTAssertEqual(call.args?["sessionId"]?.stringValue, "s-1")
        let preview = try XCTUnwrap(call.args?["preview"])
        XCTAssertEqual(preview["path"]?.stringValue, "/dsh/inbox/s-1/p.jpg")
        XCTAssertEqual(preview["mediaType"]?.stringValue, "image/jpeg")
        XCTAssertEqual(preview["name"]?.stringValue, "a.jpg")
        let original = try XCTUnwrap(call.args?["original"])
        XCTAssertEqual(original["path"]?.stringValue, "/dsh/inbox/s-1/o.heic")
        XCTAssertEqual(original["mediaType"]?.stringValue, "image/heic")
        XCTAssertEqual(call.args?["sendOriginalAsFile"]?.boolValue, true,
                       "超限/不可解码的原图必须让连接器按普通文件上传")

        let previewValue = try XCTUnwrap(value.preview)
        XCTAssertEqual(previewValue.receiptId, "rcpt-preview")
        XCTAssertEqual(previewValue.image.attachmentId, "sha256:preview")
        XCTAssertEqual(previewValue.image.bytes, 4096)
        XCTAssertEqual(previewValue.image.width, 1024)
        XCTAssertEqual(previewValue.image.height, 768)
        XCTAssertEqual(value.original?.attachmentId, "sha256:original")
        XCTAssertEqual(value.original?.name, "a.heic")
        XCTAssertEqual(value.original?.bytes, 123456)
        XCTAssertEqual(value.original?.mediaType, "image/heic")
        XCTAssertEqual(value.originalReason, "tooLarge")
        XCTAssertNil(value.fileReceiptId)
    }

    func testCommitOmitsOptionalFieldsWhenThereIsNoOriginal() async throws {
        let recorder = Recorder()
        recorder.stub("_link/imageCommit", """
        {"preview":{"receiptId":"r1","image":{"attachmentId":"sha256:a","mediaType":"image/jpeg"}}}
        """)
        let client = DSHClient(carrier: recorder)

        _ = try await client.commitImage(
            sessionId: "s-1",
            preview: ImageVariantUpload(path: "/inbox/p.jpg", mediaType: "image/jpeg", name: "p.jpg"),
            original: nil,
            sendOriginalAsFile: false
        )

        let args = try XCTUnwrap(recorder.calls.first?.args)
        XCTAssertNil(args["original"], "没有原图时不该出现 original 字段")
        XCTAssertNil(args["sendOriginalAsFile"], "false 与缺省同义，发出去只会多一处漂移")
    }

    func testCommitDecodesTheFileReceiptForOversizedOriginals() async throws {
        let recorder = Recorder()
        recorder.stub("_link/imageCommit", """
        {"preview":{"receiptId":"r2","image":{"attachmentId":"sha256:p","mediaType":"image/jpeg","bytes":10}},
         "original":null,
         "fileReceiptId":"rcpt-file",
         "originalReason":"tooLarge"}
        """)
        let client = DSHClient(carrier: recorder)

        let value = try await client.commitImage(
            sessionId: "s-1",
            preview: ImageVariantUpload(path: "/inbox/p.jpg", mediaType: "image/jpeg", name: "p.jpg"),
            original: ImageVariantUpload(path: "/inbox/o.heic", mediaType: "image/heic", name: "o.heic"),
            sendOriginalAsFile: true
        )

        XCTAssertNil(value.original)
        XCTAssertEqual(value.fileReceiptId, "rcpt-file")
        XCTAssertEqual(value.originalReason, "tooLarge")
    }

    // MARK: - 错误映射

    func testUnsupportedConnectorIsNotAUtilityFailureEvenForChunks() async throws {
        let recorder = Recorder()
        for method in ["_link/imageCommit", "_link/imageOriginal", "_link/imageOriginalChunk"] {
            recorder.fail(method, with: DSHRPCFailure(code: "link/unsupported",
                                                      message: "not bridged"))
        }
        let client = DSHClient(carrier: recorder)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.commitImage(
                sessionId: "s-1",
                preview: ImageVariantUpload(path: "/inbox/p.jpg", mediaType: "image/jpeg", name: "p.jpg"),
                original: nil,
                sendOriginalAsFile: false
            )
        } check: { XCTAssertEqual($0 as? ImageVariantsUnsupported, ImageVariantsUnsupported()) }

        await XCTAssertThrowsErrorAsync {
            _ = try await client.imageOriginal(attachmentId: "sha256:p")
        } check: { XCTAssertEqual($0 as? ImageVariantsUnsupported, ImageVariantsUnsupported()) }

        await XCTAssertThrowsErrorAsync {
            _ = try await client.imageOriginalChunk(attachmentId: "sha256:o", offset: 0, length: 1024)
        } check: { XCTAssertEqual($0 as? ImageVariantsUnsupported, ImageVariantsUnsupported()) }
    }

    func testMissingOriginalIsAnUnavailableLookupNotARetryableError() async throws {
        let recorder = Recorder()
        recorder.stub("_link/imageOriginal", #"{"available":false,"reason":"missing"}"#)
        let client = DSHClient(carrier: recorder)

        let lookup = try await client.imageOriginal(attachmentId: "sha256:p")

        XCTAssertEqual(lookup, .unavailable(reason: "missing"))
    }

    func testCleanedOriginalArrivesAsAnUnavailableLookup() async throws {
        let recorder = Recorder()
        recorder.fail("_link/imageOriginal", with: DSHRPCFailure(
            code: "image-original/cleaned", message: "object file is gone"))
        let client = DSHClient(carrier: recorder)

        let lookup = try await client.imageOriginal(attachmentId: "sha256:p")

        XCTAssertEqual(lookup, .unavailable(reason: "cleaned"))
        XCTAssertEqual(recorder.calls.count, 1, "一次查询，不是重试循环")
    }

    func testImageOriginalChunkDecodesBase64AndRange() async throws {
        let recorder = Recorder()
        let bytes = Data((0..<600).map { UInt8($0 % 251) })
        recorder.stub("_link/imageOriginalChunk", """
        {"data":"\(bytes.base64EncodedString())","offset":0,"eof":false,"bytes":1234}
        """)
        let client = DSHClient(carrier: recorder)

        let chunk = try await client.imageOriginalChunk(
            attachmentId: "sha256:o", offset: 0, length: 600)

        XCTAssertEqual(chunk.data, bytes)
        XCTAssertEqual(chunk.offset, 0)
        XCTAssertFalse(chunk.eof)
        XCTAssertEqual(chunk.bytes, 1234, "bytes 是原图总长，不是本段长度")
        let args = try XCTUnwrap(recorder.calls.first?.args)
        XCTAssertEqual(args["attachmentId"]?.stringValue, "sha256:o")
        XCTAssertEqual(args["offset"]?.intValue, 0)
        XCTAssertEqual(args["length"]?.intValue, 600)
    }

    func testChunkOfAMissingOriginalIsUnavailableAndNotRetried() async throws {
        let recorder = Recorder()
        recorder.fail("_link/imageOriginalChunk", with: DSHRPCFailure(
            code: "image-original/missing", message: "no such preview"))
        let client = DSHClient(carrier: recorder)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.imageOriginalChunk(attachmentId: "sha256:o", offset: 0, length: 1024)
        } check: {
            XCTAssertEqual($0 as? ImageOriginalUnavailable, ImageOriginalUnavailable(reason: "missing"))
        }
        XCTAssertEqual(recorder.calls.count, 1, "不可用不是网络失败：调用方不得自动重试")
    }
}

private extension XCTestCase {
    /// 断言异步闭包抛错，并把错误交给 `check`。
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        check: (any Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected an error. \(message())", file: file, line: line)
        } catch {
            check(error)
        }
    }
}
