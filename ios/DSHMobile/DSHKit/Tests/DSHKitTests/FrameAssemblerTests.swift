import Foundation
import XCTest

@testable import DSHKit

/// The assembler's job is to put back a frame the relay cut into WebSocket
/// messages. It exists because that cut is invisible: without it the first
/// fragment is dropped as malformed JSON, the rest as garbage, and the call
/// behind them hangs until its deadline.
final class FrameAssemblerTests: XCTestCase {

    private func frame(id: String, payload: String) -> Data {
        // Built by the encoder, not by hand: a payload with quotes or braces in
        // it would otherwise produce invalid JSON and the test would be
        // measuring its own escaping.
        let object: [String: Any] = ["t": "res", "id": id, "ok": true, "value": payload]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testAWholeFramePassesStraightThrough() throws {
        var assembler = FrameAssembler()
        let message = frame(id: "u1", payload: "small")

        XCTAssertEqual(try assembler.feed(message), message)
        XCTAssertFalse(assembler.isHoldingPartialFrame)
    }

    func testAFrameSplitAcrossMessagesComesBackWhole() throws {
        var assembler = FrameAssembler()
        // A payload with braces and quotes in it, so a naive "split on }" cannot
        // pass this by accident.
        let whole = frame(id: "u2", payload: String(repeating: "a}b\"c", count: 5000))
        let size = whole.count / 3

        XCTAssertNil(try assembler.feed(whole.prefix(size)))
        XCTAssertTrue(assembler.isHoldingPartialFrame)
        XCTAssertNil(try assembler.feed(whole.dropFirst(size).prefix(size)))
        XCTAssertEqual(try assembler.feed(whole.dropFirst(size * 2)), whole)
        XCTAssertFalse(assembler.isHoldingPartialFrame)
    }

    func testConsecutiveFramesAreUnaffected() throws {
        var assembler = FrameAssembler()
        let first = frame(id: "u3", payload: "one")
        let second = frame(id: "u4", payload: "two")

        XCTAssertEqual(try assembler.feed(first), first)
        XCTAssertEqual(try assembler.feed(second), second)
    }

    func testTrailingWhitespaceStillCountsAsAWholeFrame() throws {
        var assembler = FrameAssembler()
        let message = Data(#"{"t":"pong","ts":1}"#.utf8) + Data("\n".utf8)

        XCTAssertEqual(try assembler.feed(message), message)
    }

    func testBytesThatCanNeverBeAFrameAreReportedInsteadOfHeld() throws {
        var assembler = FrameAssembler(limit: 4096)

        XCTAssertNil(try assembler.feed(Data(#"{"t":"res","value":""#.utf8)))
        XCTAssertThrowsError(try assembler.feed(Data(repeating: UInt8(ascii: "x"), count: 8192))) { error in
            XCTAssertEqual(error as? FrameAssembler.Failure, .tooLarge(limit: 4096))
        }
        // The buffer is dropped, so the next real frame is not glued to rubbish.
        let next = frame(id: "u5", payload: "after")
        XCTAssertEqual(try assembler.feed(next), next)
    }

    func testResetDropsAPartialFrame() throws {
        var assembler = FrameAssembler()
        let whole = frame(id: "u6", payload: String(repeating: "abc", count: 3000))

        XCTAssertNil(try assembler.feed(whole.prefix(100)))
        assembler.reset()
        XCTAssertEqual(try assembler.feed(whole), whole)
    }
}
