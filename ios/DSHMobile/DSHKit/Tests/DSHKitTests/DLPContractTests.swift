import Foundation
import XCTest

@testable import DSHKit

/// The DLP wire vectors, shared by all three ends.
///
/// `test/contract/dlp-vectors.json` is the single source of truth: iOS (this
/// file), the connector (`plugins/mobile-link/test/dlp-contract.test.js`) and
/// the relay (`relay/tests/test_dlp_contract.py`) all read the *same* file. The
/// contract itself is `docs/relay-contract.json`.
///
/// **This test depends on the repository layout**: it walks five levels up from
/// `#filePath` to reach the repo root. Copying `ios/DSHMobile/DSHKit` out on its
/// own and running `swift test` will fail here — the vectors belong to the
/// repository, not to the package. That is deliberate: the whole point is that
/// one copy of the data is shared, and the package cannot ship its own.
final class DLPContractTests: XCTestCase {
    private struct Contract: Decodable {
        struct Drift: Decodable {
            let id: String
        }
        let protocolVersion: Int
        let maxFrameBytes: Int
        let deviceToAgent: [String]
        let agentToDevice: [String]
        let relayControl: [String]
        let idFrames: [String]
        let knownDrift: [Drift]
    }

    private struct Vector: Decodable {
        let name: String
        let t: String
        let direction: String
        let hasId: Bool
        let js: String
        let py: String
        let swift: String
        let why: String
    }

    private struct VectorFile: Decodable {
        let contract: String
        let vectors: [Vector]
    }

    /// `<repo>/test/contract/dlp-vectors.json`, found by walking up from this file.
    ///
    /// The file lives at `<repo>/ios/DSHMobile/DSHKit/Tests/DSHKitTests/DLPContractTests.swift`,
    /// so six levels up is the repository root.
    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    private func load<T: Decodable>(_ type: T.Type, at relative: String) throws -> T {
        let url = Self.repoRoot.appendingPathComponent(relative)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private var contract: Contract { get throws { try load(Contract.self, at: "docs/relay-contract.json") } }
    private var vectors: [Vector] { get throws { try load(VectorFile.self, at: "test/contract/dlp-vectors.json").vectors } }

    func testTheFrameVocabulariesMatchTheContract() throws {
        let contract = try contract
        XCTAssertEqual(DLPFrames.deviceToAgent, Set(contract.deviceToAgent))
        XCTAssertEqual(DLPFrames.agentToDevice, Set(contract.agentToDevice))
        XCTAssertEqual(DLPFrames.idFrames, Set(contract.idFrames))
    }

    func testTheProtocolConstantsMatchTheContract() throws {
        let contract = try contract
        XCTAssertEqual(dlpProtocolVersion, contract.protocolVersion)
        XCTAssertEqual(dlpMaxFrameBytes, contract.maxFrameBytes)
    }

    /// Frames iOS actually puts on the wire. `DLPFrames.deviceToAgent` is the
    /// *declared* vocabulary (it carries `"hello"`, which v1 reserves and
    /// neither end sends — see the `hello-unused` drift); these five are the
    /// ones with a real encoding site.
    private static let encodedByIOS: Set<String> = [
        DLPFrames.request, DLPFrames.open, DLPFrames.cancel, DLPFrames.eventResult, DLPFrames.ping,
    ]

    /// iOS plays both halves: it **encodes** the device→agent frames listed in
    /// `encodedByIOS` and **decodes** the agent→device ones in
    /// `LinkCarrier.handle(_:)`. `handled` therefore means "iOS has a code path
    /// for this frame in the direction it travels"; `ignored` means it has none.
    ///
    /// The `hello-unused` row is the interesting one: `hello` sits in the
    /// declared device→agent vocabulary but iOS never sends it, so the vector
    /// says `ignored` and this test would catch anyone who "fixed" that without
    /// touching the contract.
    func testEveryVectorRowIsHandledTheWayTheVectorSays() throws {
        for vector in try vectors {
            let handled: Bool
            switch vector.direction {
            case "deviceToAgent":
                handled = Self.encodedByIOS.contains(vector.t)
            case "agentToDevice":
                handled = DLPFrames.agentToDevice.contains(vector.t)
            default:
                handled = false // an unknown frame must fall through everywhere
            }
            switch vector.swift {
            case "handled":
                XCTAssertTrue(handled, "\(vector.name): 期望 handled，但 \(vector.t)（\(vector.direction)）本端没有代码路径")
            case "ignored":
                XCTAssertFalse(handled, "\(vector.name): 期望 ignored，但 \(vector.t)（\(vector.direction)）本端有代码路径")
            default:
                XCTFail("\(vector.name): 向量里的 swift 期望写法不对：\(vector.swift)")
            }
        }
    }

    /// Every id-carrying frame the contract names must be in the table — the
    /// table is what the contract test pins, so a missing entry is a drift.
    func testEveryIdFrameIsDeclared() throws {
        for kind in try contract.idFrames {
            XCTAssertTrue(DLPFrames.deviceToAgent.contains(kind) || DLPFrames.agentToDevice.contains(kind),
                          "idFrames 里的 \(kind) 没落在任何一张方向表里")
        }
    }

    func testTheSharedVectorsCoverEveryDriftTheContractRecords() throws {
        let driftIds = Set(try contract.knownDrift.map(\.id))
        let recorded = Set(try vectors.flatMap { vector in
            driftIds.filter { vector.why.contains($0) }
        })
        XCTAssertEqual(recorded, driftIds, "每条 knownDrift 至少要有一条向量在记账")
    }

    func testTheVectorsIncludeAnUnknownFrameForForwardCompatibility() throws {
        let unknown = try vectors.filter { $0.direction == "unknown" }
        XCTAssertFalse(unknown.isEmpty, "向量里必须有一条未知帧")
        for vector in unknown {
            XCTAssertFalse(DLPFrames.agentToDevice.contains(vector.t),
                           "\(vector.name): 未知帧不能被当成已知帧处理")
        }
    }
}
