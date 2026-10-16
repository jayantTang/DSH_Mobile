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

    /// 可编程响应的**存储**，一律经 `storeLock` 读写。
    ///
    /// 为什么测试直接读写的那几个字典也要上锁：`DSHCarrier` 的方法是被产品代码在
    /// **别的线程**上调的（`ChatModel.startFollowing` → `DSHClient.follow` → `stream`，
    /// 那个 await 之后已经不在主线程），而测试是在主线程上读写这些字典的
    /// （`carrier.streamResponses[…] = …`、`carrier.liveStreams[…]`）。裸字典这样用
    /// 两个方向都不安全：一边插入、另一边查找，字典的存储会被写坏。
    ///
    /// 2026-10-16 实测到一次：`-[NSIndirectTaggedPointerString objectForKey:]`
    /// （字典查找把字符串当成了字典）崩在 `FakeCarrier.stream` 里，整个 xctest 进程随之退出，
    /// XCTest 只报一句"Restarting after unexpected exit, crash, or test timeout"。
    /// 这是测试替身自己的缺陷，与产品代码无关（本模块不进 App 目标）。
    private let storeLock = NSLock()
    private var unaryResponsesStorage: [String: Result<JSONValue, Error>] = [:]
    private var streamResponsesStorage: [String: [JSONValue]] = [:]
    private var streamScriptsStorage: [String: [StreamEvent]] = [:]
    private var liveStreamsStorage: [String: AsyncThrowingStream<JSONValue, any Error>.Continuation] = [:]
    private var liveStreamWaitersStorage: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var liveStreamEndpointsStorage: Set<String> = []

    /// 一次加锁完成一段读或写；不得在锁内 await，也不得在锁内调测试代码。
    private func withStore<T>(_ body: () -> T) -> T {
        storeLock.lock()
        defer { storeLock.unlock() }
        return body()
    }

    /// 一元方法的可编程应答。按值读写（get-modify-set 的写法照旧可用）。
    public var unaryResponses: [String: Result<JSONValue, Error>] {
        get { withStore { unaryResponsesStorage } }
        set { withStore { unaryResponsesStorage = newValue } }
    }

    public var streamResponses: [String: [JSONValue]] {
        get { withStore { streamResponsesStorage } }
        set { withStore { streamResponsesStorage = newValue } }
    }

    /// 流事件：值 / 中途出错 / 悬挂（永不结束，用来测「断线中」的定格）。
    /// 029 场景测试批次：断线中途与重连续传需要「流到一半坏掉」的形状。
    public enum StreamEvent: Sendable {
        case value(JSONValue)
        case failure(Error)
        case hang
    }

    /// 逐事件回放。设置后优先于 streamResponses。
    public var streamScripts: [String: [StreamEvent]] {
        get { withStore { streamScriptsStorage } }
        set { withStore { streamScriptsStorage = newValue } }
    }

    /// 手工推进的活流：测试拿 continuation 往里补帧（重连、迟到帧场景）。
    public private(set) var liveStreams: [String: AsyncThrowingStream<JSONValue, any Error>.Continuation] {
        get { withStore { liveStreamsStorage } }
        set { withStore { liveStreamsStorage = newValue } }
    }

    public private(set) var liveStreamWaiters: [String: [CheckedContinuation<Void, Never>]] {
        get { withStore { liveStreamWaitersStorage } }
        set { withStore { liveStreamWaitersStorage = newValue } }
    }

    /// 声明「这条端点给活流」——只在显式注册后生效，否则保持静态回放语义。
    public private(set) var liveStreamEndpoints: Set<String> {
        get { withStore { liveStreamEndpointsStorage } }
        set { withStore { liveStreamEndpointsStorage = newValue } }
    }

    public func registerLiveStream(_ endpoint: String) {
        withStore { _ = liveStreamEndpointsStorage.insert(endpoint) }
    }

    /// 等某条活流被订阅（防止测试帧在订阅前丢出）。
    public func waitForLiveStream(_ endpoint: String) async {
        await withCheckedContinuation { c in
            // 流程只有一句：登记成功就等订阅来唤醒，不成功说明流已经在了（立刻继续）。
            if !claimWaiter(endpoint, c) { c.resume() }
        }
    }

    /// 登记一个等待者。返回 false = 这条端点的流已经注册，调用方不该再挂起。
    ///
    /// 为什么必须把"看有没有流"和"挂上等待者"放进**同一把锁**：原来的写法是
    /// 先查 `liveStreams`、再进锁登记。两步之间恰好来一次订阅（`stream()` 会一次性
    /// 取走当时的等待者列表），这个等待者就再也没人唤醒——表现为**整套用例无声挂死**
    /// （2026-10-17 两次实测：`sample` 显示卡在 `XCTWaiter`，一次 23 分钟、一次 50 分钟）。
    /// 抽成同步函数是为了让这段竞态能被单测直接钉住，不必靠调度碰运气。
    @discardableResult
    func claimWaiter(_ endpoint: String,
                     _ continuation: CheckedContinuation<Void, Never>) -> Bool {
        withStore {
            guard liveStreamsStorage[endpoint] == nil else { return false }
            // 追加在锁内一次做完：`default: []` 的读-改-写分两步会丢掉同时进来的等待者。
            liveStreamWaitersStorage[endpoint, default: []].append(continuation)
            return true
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
        guard let response = withStore({ unaryResponsesStorage[method] }) else {
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
        // 一次加锁把这三种路由依据都取出来：分三次查等于给并发写留三个窗口。
        let (script, responses, isLiveEndpoint) = withStore {
            (streamScriptsStorage[endpoint], streamResponsesStorage[endpoint],
             liveStreamEndpointsStorage.contains(endpoint))
        }
        if let script {
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
        if script == nil, responses == nil, isLiveEndpoint {
            let key = endpoint
            return AsyncThrowingStream { continuation in
                // 登记与唤醒在锁内一次做完，续体在锁外恢复（恢复会执行测试代码）。
                let pending: [CheckedContinuation<Void, Never>] = withStore {
                    liveStreamsStorage[key] = continuation
                    let waiters = liveStreamWaitersStorage[key] ?? []
                    liveStreamWaitersStorage[key] = nil
                    return waiters
                }
                for w in pending { w.resume() }
            }
        }
        let values = responses ?? []
        return AsyncThrowingStream { continuation in
            for v in values { continuation.yield(v) }
            continuation.finish()
        }
    }

    public func eventResult(_ result: JSONValue) async throws {}

    public func close() async {}
}
