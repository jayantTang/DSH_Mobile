import DSHKit
import Foundation

/// 假传输层：按方法名路由到可编程响应，记录全部调用（方法名 + 编码后的参数）。
/// 供 Chat/Sessions 等 DomainTests 验证"发了什么 RPC、带了什么参数、顺序如何"。
public final class FakeCarrier: DSHCarrier, @unchecked Sendable {
    public struct RecordedCall: Sendable, Equatable {
        public let method: String
        /// 参数按 wire 上的形状编成 JSON（`RequestArgs` 会包一层 `request`）。
        ///
        /// 记的是**编码结果**而不是原始值：被测代码写到线上的那一层才是契约，
        /// 泛型值本身也没法跨方法比较，看不出信封有没有包错。
        public let args: JSONValue?

        public init(method: String, args: JSONValue? = nil) {
            self.method = method
            self.args = args
        }
    }

    /// 全部调用，按发生顺序。
    ///
    /// 记录本身加了锁：产品代码会在并发任务里发 RPC（冷启动预取瀑布就是并发 3 取页），
    /// 而 `calls` 又是在**后台任务跑着的时候**被读的（"等到安静下来再断言"那条路）。
    /// 裸数组在这种用法下两个方向都不安全：并发 `append` 会互相覆盖（丢记录），
    /// 读到一半的 `append` 会让计数变成随机值。锁只护这一处，不动任何产品语义。
    public var calls: [RecordedCall] {
        callLock.lock()
        defer { callLock.unlock() }
        return recordedCalls
    }

    private let callLock = NSLock()
    private var recordedCalls: [RecordedCall] = []
    public var unaryResponses: [String: Result<JSONValue, Error>] = [:]
    public var streamResponses: [String: [JSONValue]] = [:]

    /// 流事件：值 / 中途出错 / 悬挂（永不结束，用来测「断线中」的定格）。
    /// 029 场景测试批次：断线中途与重连续传需要「流到一半坏掉」的形状。
    public enum StreamEvent: Sendable {
        case value(JSONValue)
        case failure(Error)
        case hang
    }
    /// 逐事件回放。设置后优先于 streamResponses。
    public var streamScripts: [String: [StreamEvent]] = [:]

    /// 手工推进的活流：测试拿 continuation 往里补帧（重连、迟到帧场景）。
    public private(set) var liveStreams: [String: AsyncThrowingStream<JSONValue, any Error>.Continuation] = [:]
    public private(set) var liveStreamWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// 声明「这条端点给活流」——只在显式注册后生效，否则保持静态回放语义。
    public private(set) var liveStreamEndpoints: Set<String> = []
    public func registerLiveStream(_ endpoint: String) { liveStreamEndpoints.insert(endpoint) }

    /// 等某条活流被订阅（防止测试帧在订阅前丢出）。
    public func waitForLiveStream(_ endpoint: String) async {
        if liveStreams[endpoint] != nil { return }
        await withCheckedContinuation { c in
            liveStreamWaiters[endpoint, default: []].append(c)
        }
    }

    public init() {}

    private func record(_ call: RecordedCall) {
        callLock.lock()
        defer { callLock.unlock() }
        recordedCalls.append(call)
    }

    /// 按方法名筛记录：调用顺序里掺着后台任务，按下标取不稳。
    public func calls(to method: String) -> [RecordedCall] {
        calls.filter { $0.method == method }
    }

    /// 把一个 Encodable 参数编成 `JSONValue`；编不出来记 nil，不抛。
    static func encoded<Args: Encodable>(_ args: Args) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(args) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String, args: Args, as valueType: Value.Type
    ) async throws -> Value {
        record(RecordedCall(method: method, args: Self.encoded(args)))
        guard let response = unaryResponses[method] else {
            throw NSError(domain: "FakeCarrier", code: 1, userInfo: [NSLocalizedDescriptionKey: "no stub for \(method)"])
        }
        switch response {
        case .success(let value):
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(Value.self, from: data)
        case .failure(let error):
            throw error
        }
    }

    public func stream<Args: Encodable & Sendable>(
        endpoint: String, args: Args
    ) async -> AsyncThrowingStream<JSONValue, any Error> {
        record(RecordedCall(method: endpoint, args: Self.encoded(args)))
        if let script = streamScripts[endpoint] {
            return AsyncThrowingStream { continuation in
                for event in script {
                    switch event {
                    case .value(let v): continuation.yield(v)
                    case .failure(let e): continuation.finish(throwing: e)
                    case .hang: return  // 不结束，调用方悬在流上
                    }
                }
                continuation.finish()
            }
        }
        // 已注册的活流端点：测试可 waitForLiveStream 后往里推。
        if streamScripts[endpoint] == nil, streamResponses[endpoint] == nil, liveStreamEndpoints.contains(endpoint) {
            let key = endpoint
            return AsyncThrowingStream { continuation in
                liveStreams[key] = continuation
                for w in liveStreamWaiters[key] ?? [] { w.resume() }
                liveStreamWaiters[key] = nil
            }
        }
        let values = streamResponses[endpoint] ?? []
        return AsyncThrowingStream { continuation in
            for v in values { continuation.yield(v) }
            continuation.finish()
        }
    }

    public func eventResult(_ result: JSONValue) async throws {}

    public func close() async {}
}
