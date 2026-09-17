import Foundation
import Testing

@testable import DSHKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Device management is a *relay* HTTP call, so these tests drive a stubbed
/// URLSession rather than a carrier: the interesting behaviour is the request
/// that goes out and how the relay's answers and failures are surfaced.
// Serialised: the stub keeps its canned answers in static storage, so
// concurrent tests would consume each other's responses.
@Suite("Relay device management", .serialized)
struct RelayDeviceAdminTests {

    /// A URLProtocol that records requests and replays canned answers.
    final class Stub: URLProtocol, @unchecked Sendable {
        struct Exchange: Sendable {
            let status: Int
            let body: Data
        }

        nonisolated(unsafe) static var exchanges: [Exchange] = []
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var bodies: [Data] = []

        static func reset(_ list: [Exchange]) {
            exchanges = list
            requests = []
            bodies = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            // A body set via `httpBody` arrives on the stream; URLProtocol sees
            // it as `httpBodyStream`, so read it back for assertions.
            var body = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    body.append(contentsOf: buffer[0 ..< read])
                }
                stream.close()
            } else if let direct = request.httpBody {
                body = direct
            }
            Self.bodies.append(body)

            let exchange = Self.exchanges.isEmpty
                ? Exchange(status: 500, body: Data("{}".utf8))
                : Self.exchanges.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: exchange.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: exchange.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Stub.self]
            return URLSession(configuration: configuration)
        }
    }

    private func admin(relay: String = "https://relay.test/dsh-link") -> RelayDeviceAdmin {
        RelayDeviceAdmin(
            relayURL: URL(string: relay)!,
            deviceToken: "dt_phone",
            session: Stub.session()
        )
    }

    @Test("the device list goes to the relay under its mount prefix")
    func listRequest() async throws {
        Stub.reset([.init(status: 200, body: Data("""
        {"ok":true,"currentDeviceId":"dev_me","devices":[
          {"deviceId":"dev_me","name":"Example iPhone","model":"iPhone17,1","createdAt":1700000000000,"lastSeenAt":1700000060000,"revoked":false},
          {"deviceId":"dev_old","name":"old phone","model":"iPhone15,2","createdAt":1690000000000,"lastSeenAt":null,"revoked":false}
        ]}
        """.utf8))])

        let list = try await admin().devices()
        #expect(list.devices.count == 2)
        #expect(list.currentDeviceId == "dev_me")
        #expect(list.devices[0].isCurrent)
        #expect(!list.devices[1].isCurrent)
        #expect(list.devices[0].displayName == "Example iPhone")
        #expect(list.devices[1].lastSeenAt == nil)
        #expect(list.devices[0].createdAt != nil)

        let request = try #require(Stub.requests.first)
        #expect(request.url?.absoluteString == "https://relay.test/dsh-link/devices")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dt_phone")
    }

    @Test("a relay with no mount prefix still works")
    func listWithoutPrefix() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"ok":true,"currentDeviceId":"dev_me","devices":[]}"#.utf8))])
        _ = try await admin(relay: "https://relay.test").devices()
        #expect(Stub.requests.first?.url?.absoluteString == "https://relay.test/devices")
    }

    @Test("revoking posts the device id and reports success")
    func revokeRequest() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"ok":true,"deviceId":"dev_old"}"#.utf8))])
        let revoked = try await admin().revokeDevice(id: "dev_old")
        #expect(revoked == "dev_old")

        let request = try #require(Stub.requests.first)
        #expect(request.url?.absoluteString == "https://relay.test/dsh-link/devices/revoke")
        #expect(request.httpMethod == "POST")
        let body = try #require(Stub.bodies.first)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(decoded?["deviceId"] == "dev_old")
    }

    @Test("a rejected token surfaces the relay's own error")
    func rejectedToken() async throws {
        Stub.reset([.init(status: 401, body: Data(#"{"ok":false,"error":{"code":"auth/invalid-token","message":"a valid device token is required"}}"#.utf8))])
        await #expect(throws: DSHRPCFailure.self) {
            _ = try await admin().devices()
        }
    }

    @Test("revoking another agent's device is refused, not silently ignored")
    func foreignDeviceRefused() async throws {
        Stub.reset([.init(status: 403, body: Data(#"{"ok":false,"error":{"code":"auth/agent-mismatch","message":"that device belongs to another agent"}}"#.utf8))])
        do {
            _ = try await admin().revokeDevice(id: "dev_theirs")
            Issue.record("a 403 must not look like success")
        } catch let failure as DSHRPCFailure {
            #expect(failure.code == "auth/agent-mismatch")
        }
    }

    @Test("a non-JSON answer is an HTTP failure, not a decode crash")
    func malformedAnswer() async throws {
        Stub.reset([.init(status: 200, body: Data("<html>nope</html>".utf8))])
        await #expect(throws: DSHTransportError.self) {
            _ = try await admin().devices()
        }
    }

    @Test("revoked devices are filtered out of the visible list")
    func revokedFiltered() {
        let list = RelayDeviceList(devices: [
            RelayDevice(deviceId: "dev_live", name: "live", revoked: false),
            RelayDevice(deviceId: "dev_dead", name: "dead", revoked: true),
        ], currentDeviceId: "dev_live")
        #expect(list.active.map(\.deviceId) == ["dev_live"])
    }

    @Test("a device without a name gets a readable label")
    func unnamedDevice() {
        #expect(RelayDevice(deviceId: "dev_x").displayName == "未命名设备")
        #expect(RelayDevice(deviceId: "dev_x", name: "   ").displayName == "未命名设备")
    }

    @Test("the carrier exposes its relay identity for the device screen")
    func carrierExposesRelay() async {
        let carrier = LinkCarrier(configuration: LinkConfiguration(
            relayURL: URL(string: "https://relay.test/dsh-link")!,
            agentId: "agt_1",
            deviceToken: "dt_1"
        ))
        let relay = carrier.relay
        #expect(relay?.url.absoluteString == "https://relay.test/dsh-link")
        #expect(relay?.deviceToken == "dt_1")
        #expect(relay?.agentId == "agt_1")
        let admin = await carrier.deviceAdmin()
        #expect(admin.relayURL.absoluteString == "https://relay.test/dsh-link")
        #expect(admin.deviceToken == "dt_1")
        await carrier.close()
    }
}
