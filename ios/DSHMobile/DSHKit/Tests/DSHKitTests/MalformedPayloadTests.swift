import Foundation
import XCTest

@testable import DSHKit

/// 异常输入不崩：随机/畸形 JSON 喂给协议解码入口，只要求安全返回。
/// 这些入口来自网络，任何“只在自己人喂的合法数据上成立”的假设都不能进发布版。
final class MalformedPayloadTests: XCTestCase {

    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
    }

    private func randomJSON(_ rng: inout LCG, depth: Int = 0) -> String {
        switch rng.int(depth > 2 ? 4 : 7) {
        case 0: return "null"
        case 1: return rng.next() % 2 == 0 ? "true" : "false"
        case 2: return String(Int64(rng.next() % 10_000) - 5_000)
        case 3: return "\"\(["", "abc", "\\u0000", "\\\"", "表格 | 表头 |"][rng.int(5)])\""
        case 4: return "[" + (0..<rng.int(4)).map { _ in randomJSON(&rng, depth: depth + 1) }.joined(separator: ",") + "]"
        case 5:
            let keys = ["v", "turn", "groups", "steps", "id", "content", "next-turn", "inbox"]
            let pairs = (0..<rng.int(4)).map { _ in
                "\"\(keys[rng.int(keys.count)])\":" + randomJSON(&rng, depth: depth + 1)
            }
            return "{" + pairs.joined(separator: ",") + "}"
        default: return "{}"
        }
    }

    func test_random_frames_never_crash_the_queue_or_fold_decoders() {
        var rng = LCG(state: 0x5EED_2026)
        for _ in 0..<400 {
            let json = randomJSON(&rng)
            let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            guard let value else { continue }
            _ = SessionControlFrame.decode(value)
            _ = SessionQueuedItem.decode(value)

            let eventJSON = "{\"type\":\"+link/fold\",\"seq\":1,\"data\":\(json)}"
            if let event = try? JSONDecoder().decode(SessionEvent.self, from: Data(eventJSON.utf8)) {
                _ = FoldSummaryV2.decode(event)
            }
        }
    }

    func test_truncated_and_non_utf8_bytes_are_rejected_without_crashing() {
        for data in [Data(), Data([0xFF, 0xFE, 0x00]), Data("{\"type\":".utf8), Data(repeating: 0x7B, count: 10_000)] {
            _ = try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }
}
