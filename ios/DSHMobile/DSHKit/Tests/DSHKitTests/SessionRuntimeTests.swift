import XCTest

@testable import DSHKit

/// 门面骨架的用例（spec 023 / Phase 2b，T062–T064）。
///
/// 这一批只钉三件事：门面能造出来、它读的是注入的来源（不是全局状态）、只读模型的默认值符合
/// 契约。真正的能力（窗口、监管、编排）在自己批次里补用例。
@MainActor
final class SessionRuntimeTests: XCTestCase {

    func testFactoryReturnsRuntimeBackedByInjectedSource() {
        let runtime = makeSessionRuntime(transport: {
            TransportStateSnapshot(phase: .connected, backoffLevel: 0, connectorVersion: 3)
        })
        XCTAssertEqual(runtime.transport.phase, .connected)
        XCTAssertEqual(runtime.transport.connectorVersion, 3)
    }

    func testTransportIsReadThroughOnEveryAccess() {
        // 门面不该缓存：注入的来源变了，下一次读就该是新值（S2 的监管状态会随时变）。
        var phase = TransportStateSnapshot.Phase.dialing
        let runtime = makeSessionRuntime(transport: { TransportStateSnapshot(phase: phase) })
        XCTAssertEqual(runtime.transport.phase, .dialing)
        phase = .backoff
        XCTAssertEqual(runtime.transport.phase, .backoff)
    }

    func testDefaultSnapshotIsIdleAndSupported() {
        let snapshot = TransportStateSnapshot()
        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertEqual(snapshot.backoffLevel, 0)
        XCTAssertNil(snapshot.connectorVersion)
        XCTAssertTrue(snapshot.isConnectorSupported, "没握手之前不该把连接器判成不支持")
    }

    func testSnapshotIsAValueTypeWithoutBehaviour() {
        // 只读模型是可比较的值：视图拿它做 diff，不该有引用语义。
        let a = TransportStateSnapshot(phase: .backoff, backoffLevel: 2)
        let b = TransportStateSnapshot(phase: .backoff, backoffLevel: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, TransportStateSnapshot(phase: .backoff, backoffLevel: 3))
    }
}
