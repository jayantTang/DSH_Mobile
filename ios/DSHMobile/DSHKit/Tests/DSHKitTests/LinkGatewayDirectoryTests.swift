import Foundation
import XCTest

@testable import DSHKit

/// `_link/dirListing` 的通道切换（设计 20261024-工作区文件修改时间 §M2）。
///
/// 一个决策点（`LinkGateway.workspaceFiles`）：有能力且有 root 才走新方法；
/// 新方法失败时的回退只有一条规矩——**目录本身的事实**（`workspace-file/*`）
/// 原样上抛，其余一律回退旧通道。断言看的是替身 carrier 记下的调用次序，
/// 因为"回退"这个动作的全部内容就是"又发了一次哪个方法"。
///
/// 底座刻意只用 `DSHKit` 自己的类型：`DSHTestingSupport` 依赖本包，
/// 本包的测试反向 import 会成环（包外那条 `DSHFilesDomainTests` 用例覆盖模型层）。
@MainActor
final class LinkGatewayDirectoryTests: XCTestCase {

    private let scopeId = "s-1"
    private let root = "/Users/tester/work"

    /// 一个按方法名回包的替身：只认 `workspaceFiles/list` 与 `_link/dirListing`，
    /// 记录每次都发了什么方法、带了什么参数。
    private final class Host: DSHCarrier, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        private var encodedArgs: [[String: JSONValue]] = []

        var listing: JSONValue = .object(["path": .string(""), "truncated": .bool(false), "entries": .array([])])
        var enhanced: Result<JSONValue, any Error> = .failure(DSHTransportError.carrierClosed)

        var methods: [String] { lock.withLock { recorded } }
        var args: [[String: JSONValue]] { lock.withLock { encodedArgs } }

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String, args: Args, as valueType: Value.Type
        ) async throws -> Value {
            let encoded = (try? JSONEncoder().encode(args)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            lock.withLock {
                recorded.append(method)
                encodedArgs.append(encoded?.objectValue ?? [:])
            }
            switch method {
            case "workspaceFiles/list":
                return try Self.decode(Value.self, listing)
            case "_link/dirListing":
                return try Self.decode(Value.self, enhanced.get())
            default:
                throw DSHRPCFailure(code: "test/unknown-method", message: method)
            }
        }

        func stream<Args: Encodable & Sendable>(
            endpoint: String, args: Args
        ) async -> AsyncThrowingStream<JSONValue, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func eventResult(_ result: JSONValue) async throws {}
        func close() async {}

        static func decode<Value: Decodable>(_ type: Value.Type, _ value: JSONValue) throws -> Value {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(Value.self, from: data)
        }
    }

    private func gateway(_ carrier: Host, capabilities: Set<String>) -> LinkGateway {
        LinkGateway(clientProvider: {
            HostClientFactory.make(carrier: carrier, capabilities: capabilities)
        })
    }

    private func plainListing() -> JSONValue {
        .object([
            "path": .string(""),
            "truncated": .bool(false),
            "entries": .array([.object(["name": .string("a.txt"), "type": .string("file"), "size": .int(5)])]),
        ])
    }

    private func enhancedListing() -> JSONValue {
        .object([
            "path": .string(""),
            "truncated": .bool(false),
            "entries": .array([.object([
                "name": .string("a.txt"), "type": .string("file"), "size": .int(5),
                "mtimeMs": .int(1_761_263_400_000),
            ])]),
        ])
    }

    func test_with_capability_and_root_the_link_asks_the_connector() async throws {
        let carrier = Host()
        carrier.listing = plainListing()
        carrier.enhanced = .success(enhancedListing())

        let value = try await gateway(carrier, capabilities: [HostClientFactory.dirMtimesCapability])
            .workspaceFiles(scopeId: scopeId, path: ".", root: root)

        XCTAssertEqual(value, enhancedListing())
        XCTAssertEqual(carrier.methods, ["_link/dirListing"], "有这条通道就不该再问旧方法")
        XCTAssertEqual(carrier.args[0]["root"]?.stringValue, root, "root 必须随请求发出去")
        XCTAssertEqual(carrier.args[0]["path"]?.stringValue, ".")
    }

    func test_without_the_capability_the_old_method_is_used() async throws {
        let carrier = Host()
        carrier.listing = plainListing()

        let value = try await gateway(carrier, capabilities: [])
            .workspaceFiles(scopeId: scopeId, path: ".", root: root)

        XCTAssertEqual(value, plainListing())
        XCTAssertEqual(carrier.methods, ["workspaceFiles/list"])
    }

    func test_without_a_root_the_old_method_is_used() async throws {
        let carrier = Host()
        carrier.listing = plainListing()

        let value = try await gateway(carrier, capabilities: [HostClientFactory.dirMtimesCapability])
            .workspaceFiles(scopeId: scopeId, path: ".", root: nil)

        XCTAssertEqual(value, plainListing())
        XCTAssertEqual(carrier.methods, ["workspaceFiles/list"], "没有 root 就补不了时间，别白跑一趟")
    }

    func test_an_empty_root_is_treated_as_no_root() async throws {
        let carrier = Host()
        carrier.listing = plainListing()
        carrier.enhanced = .success(enhancedListing())

        _ = try await gateway(carrier, capabilities: [HostClientFactory.dirMtimesCapability])
            .workspaceFiles(scopeId: scopeId, path: ".", root: "")

        XCTAssertEqual(carrier.methods, ["workspaceFiles/list"])
    }

    func test_a_link_failure_falls_back_and_still_returns_the_directory() async throws {
        let carrier = Host()
        carrier.listing = plainListing()
        carrier.enhanced = .failure(DSHRPCFailure(code: "link/failed", message: "boom"))

        let value = try await gateway(carrier, capabilities: [HostClientFactory.dirMtimesCapability])
            .workspaceFiles(scopeId: scopeId, path: ".", root: root)

        XCTAssertEqual(value, plainListing(), "增强通道不可用不弄坏列表")
        XCTAssertEqual(carrier.methods, ["_link/dirListing", "workspaceFiles/list"])
    }

    func test_a_transport_failure_falls_back_too() async throws {
        let carrier = Host()
        carrier.listing = plainListing()
        carrier.enhanced = .failure(DSHTransportError.carrierClosed)

        _ = try await gateway(carrier, capabilities: [HostClientFactory.dirMtimesCapability])
            .workspaceFiles(scopeId: scopeId, path: ".", root: root)

        XCTAssertEqual(carrier.methods, ["_link/dirListing", "workspaceFiles/list"])
    }

    func test_a_directory_failure_is_rethrown_and_not_retried() async {
        let carrier = Host()
        carrier.listing = plainListing()
        carrier.enhanced = .failure(DSHRPCFailure(code: "workspace-file/not-directory", message: "not a directory"))

        do {
            _ = try await gateway(carrier, capabilities: [HostClientFactory.dirMtimesCapability])
                .workspaceFiles(scopeId: scopeId, path: ".", root: root)
            XCTFail("目录本身的事实应当原样上抛")
        } catch {
            XCTAssertEqual((error as? DSHRPCFailure)?.code, "workspace-file/not-directory")
        }
        XCTAssertEqual(carrier.methods, ["_link/dirListing"],
                       "重试必现的失败不该再打一次宿主（防雪崩式重试）")
    }

    func test_without_a_link_nothing_is_called() async {
        let carrier = Host()
        carrier.listing = plainListing()
        let gateway = LinkGateway(clientProvider: { nil })
        do {
            _ = try await gateway.workspaceFiles(scopeId: scopeId, path: ".", root: root)
            XCTFail("没有链路时应当抛错")
        } catch {
            XCTAssertTrue(error is DSHTransportError)
        }
        XCTAssertEqual(carrier.methods, [])
    }

    func test_the_declared_capability_name_is_the_one_query_sends() {
        // 三处必须同一个字符串：连接器声明的能力、App 的判定常量、契约词表
        // （`check:contracts` 比对前两者，这里钉住 App 这一侧不许改成别的写法）。
        XCTAssertEqual(HostClientFactory.dirMtimesCapability, "dir-mtimes")
    }
}

private extension Result where Failure == any Error {
    func get() throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
