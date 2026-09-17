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
