import DSHConnectionAPI
import DSHTestingSupport
import Observation
import XCTest

/// `ConnectionEnv` 是 UI 读连接状态的唯一入口；转发层必须保持 SwiftUI 的观察链。
@MainActor
final class ConnectionEnvTests: XCTestCase {

    func testStateChangeIsObservedThroughForwardingEnv() {
        let service = FakeLinkService()
        let env = ConnectionEnv(service)
        var fired = false

        withObservationTracking {
            _ = env.state
        } onChange: {
            fired = true
        }

        service.state = .connecting("dialing")
        XCTAssertTrue(fired, "env.state must forward to the service observation registrar")
    }

    func testHostHomeSetterForwardsToService() {
        let service = FakeLinkService()
        let env = ConnectionEnv(service)
        env.hostHome = "/Users/example"
        XCTAssertEqual(service.hostHome, "/Users/example")
    }

    func testFileTransferAndNoticeHelpersForward() {
        let service = FakeLinkService(capabilities: ["background-transfer"])
        let env = ConnectionEnv(service)
        XCTAssertTrue(env.supportsFileTransfer)
        XCTAssertFalse(env.showsOutdatedConnectorNotice)
    }
}
