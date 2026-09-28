import Foundation
import XCTest

@testable import DSHKit

/// Tests for relay addressing.
///
/// The relay can be mounted at the root of a host or under a path prefix so it
/// can share an existing domain and certificate. Getting the join wrong
/// silently targets the wrong endpoint, which surfaces as an opaque handshake
/// failure rather than a clear error — so it is pinned here.
final class LinkConfigurationTests: XCTestCase {

    private func configuration(for relay: String, agentId: String = "agt_1") throws -> LinkConfiguration {
        let url = try XCTUnwrap(URL(string: relay))
        return LinkConfiguration(relayURL: url, agentId: agentId, deviceToken: "dt_1")
    }

    func testRootMountedRelayProducesRootPaths() throws {
        let configuration = try configuration(for: "https://dsh.example.com")
        let url = try XCTUnwrap(configuration.socketURL)
        XCTAssertEqual(url.scheme, "wss", "an https relay must upgrade over wss")
        XCTAssertEqual(url.path, "/link/device")
        XCTAssertEqual(url.query, "agentId=agt_1")
    }

    func testPathPrefixedRelayKeepsItsPrefix() throws {
        let configuration = try configuration(for: "https://www.example.com/dsh-link")
        let url = try XCTUnwrap(configuration.socketURL)
        XCTAssertEqual(
            url.path,
            "/dsh-link/link/device",
            "the mount prefix must be preserved, not replaced"
        )
    }

    func testTrailingSlashOnTheRelayDoesNotDoubleUp() throws {
        let configuration = try configuration(for: "https://www.example.com/dsh-link/")
        let url = try XCTUnwrap(configuration.socketURL)
        XCTAssertEqual(url.path, "/dsh-link/link/device")
    }

    func testPlainHTTPRelayUpgradesToPlainWebSocket() throws {
        // Used when testing the relay on a local port before it is published.
        let configuration = try configuration(for: "http://127.0.0.1:8787")
        let url = try XCTUnwrap(configuration.socketURL)
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.path, "/link/device")
    }

    func testAppendingJoinsEveryShape() throws {
        let cases: [(String, String)] = [
            ("https://h", "/pair/claim"),
            ("https://h/", "/pair/claim"),
            ("https://h/dsh-link", "/dsh-link/pair/claim"),
            ("https://h/dsh-link/", "/dsh-link/pair/claim"),
            ("https://h/a/b", "/a/b/pair/claim"),
            ("http://127.0.0.1:8787", "/pair/claim"),
        ]
        for (base, expected) in cases {
            let url = try XCTUnwrap(URL(string: base))
            XCTAssertEqual(
                LinkConfiguration.appending(path: "/pair/claim", to: url),
                expected,
                "unexpected join for \(base)"
            )
        }
    }

    /// The shared vectors — `<repo>/test/contract/relay-base-path-vectors.json`.
    ///
    /// `appending(path:to:)` is one of **four** copies of the "join a
    /// relay-relative path onto a base" rule (the connector's
    /// `dlp.js:joinRelayPath`, the relay's `relay.py:normalize_base_path`, and
    /// the test harness's `test/tools/relaypair.mjs:route`). All four read the
    /// same file, so a change to any one of them shows up here.
    ///
    /// **Depends on the repository layout**: six levels up from `#filePath` is
    /// the repo root. Copying DSHKit out on its own makes this fail; the vectors
    /// belong to the repository, not to the package.
    private struct BasePathVector: Decodable {
        let base: String
        let suffix: String
        let path: String
        let ends: [String]
        let swiftPath: String?
        let knownDrift: String?
    }

    private struct BasePathVectors: Decodable {
        let cases: [BasePathVector]
    }

    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    func testAppendingMatchesTheSharedBasePathVectors() throws {
        let file = Self.repoRoot.appendingPathComponent("test/contract/relay-base-path-vectors.json")
        let vectors = try JSONDecoder().decode(BasePathVectors.self, from: Data(contentsOf: file))
        let covered = vectors.cases.filter { $0.ends.contains("swift") }
        XCTAssertFalse(covered.isEmpty, "向量里没有任何一行标了 swift")

        for vector in covered {
            let base = try XCTUnwrap(URL(string: vector.base), "base 解析失败：\(vector.base)")
            let expected = try XCTUnwrap(vector.swiftPath, "\(vector.base)+\(vector.suffix) 缺 swiftPath")
            XCTAssertEqual(
                LinkConfiguration.appending(path: vector.suffix, to: base),
                expected,
                "base=\(vector.base) suffix=\(vector.suffix)"
            )
        }
    }

    /// The rows that record the disagreement are the point of the file: they
    /// pin today's behaviour (a suffix without a leading slash is concatenated
    /// verbatim) rather than an idealised one.
    func testTheDocumentedJoinDriftIsStillWhatHappens() throws {
        let file = Self.repoRoot.appendingPathComponent("test/contract/relay-base-path-vectors.json")
        let vectors = try JSONDecoder().decode(BasePathVectors.self, from: Data(contentsOf: file))
        let drifted = vectors.cases.filter { $0.knownDrift != nil && $0.ends.contains("swift") }
        XCTAssertFalse(drifted.isEmpty, "向量里应当有标了 knownDrift 的 swift 行")
        for vector in drifted {
            let base = try XCTUnwrap(URL(string: vector.base))
            XCTAssertEqual(
                LinkConfiguration.appending(path: vector.suffix, to: base),
                vector.swiftPath,
                "\(vector.base)+\(vector.suffix) 的现状值变了：向量要跟着改，并重新判断生产是否可达"
            )
        }
    }

    func testRelayOriginIsNormalisedToItsHTTPForm() throws {
        // A relay advertises `wss://` because that is what the connector dials,
        // but the phone also calls `/pair/claim` over HTTP. Both must derive
        // from one stored address, and the mount prefix must survive.
        let cases: [(String, String?)] = [
            ("wss://www.example.com/dsh-link", "https://www.example.com/dsh-link"),
            ("ws://127.0.0.1:8787", "http://127.0.0.1:8787"),
            ("https://www.example.com/dsh-link", "https://www.example.com/dsh-link"),
            ("http://127.0.0.1:8787/", "http://127.0.0.1:8787/"),
            ("ftp://example.com", nil),
        ]
        for (input, expected) in cases {
            let url = try XCTUnwrap(URL(string: input))
            let normalized = LinkConfiguration.normalizedRelayURL(url)
            XCTAssertEqual(normalized?.absoluteString, expected, "unexpected normalisation for \(input)")
        }
    }

    func testNormalisedRelayStillProducesAWSSSocket() throws {
        let relay = try XCTUnwrap(URL(string: "wss://www.example.com/dsh-link"))
        let normalized = try XCTUnwrap(LinkConfiguration.normalizedRelayURL(relay))
        let configuration = LinkConfiguration(relayURL: normalized, agentId: "a", deviceToken: "t")
        let url = try XCTUnwrap(configuration.socketURL)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/dsh-link/link/device")
    }
}
