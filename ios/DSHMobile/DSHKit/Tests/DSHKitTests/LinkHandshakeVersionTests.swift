import Foundation
import Testing

@testable import DSHKit

/// `_link/hello` 的应答里那两段版本：连接器（`serverVersion`）与宿主 DSH（`hostVersion`）。
@Suite("LinkHandshake versions")
struct LinkHandshakeVersionTests {

    private func decode(_ json: String) throws -> LinkHandshake {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(LinkHandshake.self, from: data)
    }

    @Test("宿主版本按原样解出来，与连接器版本互不混淆")
    func decodesBothNamespaces() throws {
        let handshake = try decode(#"""
        {"serverVersion":"0.6.5","hostVersion":"0.2.0-rc.2","capabilities":["file-transfer"],
         "protocolVersion":1,"agentId":"agt_1","name":"my mac"}
        """#)
        #expect(handshake.serverVersion == "0.6.5")
        #expect(handshake.hostVersion == "0.2.0-rc.2")
    }

    @Test("老连接器不报宿主版本：解成 nil，不编一个")
    func toleratesAMissingHostVersion() throws {
        let handshake = try decode(#"{"serverVersion":"0.5.0","capabilities":[]}"#)
        #expect(handshake.serverVersion == "0.5.0")
        #expect(handshake.hostVersion == nil)
    }

    @Test("类型不对也不抛错：整个握手照常可用")
    func ignoresAMalformedHostVersion() throws {
        let handshake = try decode(#"{"serverVersion":"0.6.5","hostVersion":42,"capabilities":[]}"#)
        #expect(handshake.hostVersion == nil)
        #expect(handshake.serverVersion == "0.6.5")
    }
}
