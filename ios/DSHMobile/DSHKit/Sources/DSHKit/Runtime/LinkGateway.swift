import Foundation

/// 链路能力（spec 023 边界收敛：门面按能力给窄对象）。
///
/// ## 为什么需要它
///
/// App 里除了连接本身（`ConnectionStore`）以外，还有六处在用链路：设置页要问"电脑端连接器"的
/// 状态、事件中枢要订会话事件并回答、文件页要读工作区目录、列表要拿 workspace 基线、启动接线要
/// 决定要不要开链路、网页视图要读文件内容。它们原来都直接拿着 `DSHClient`（两处还穿透到
/// `client.carrier as? LinkCarrier`），于是产品路径里到处是实现层的类型名。
///
/// 这个能力对象把**用到的那几个动作**转出来，`DSHClient` / `LinkCarrier` 的名字只留在
/// `ConnectionStore`（连接适配器，白名单文件）里。
///
/// ## 边界
///
/// * 它**不持有连接**：只拿一个"现取 client"的闭包（重连换了 carrier 也自动跟上，与
///   `MessageLayer.attach` 同一约定）；
/// * 它**不做重连**：那是 `LinkSupervisor` + `ConnectionStore` 的事；
/// * 它有一个**判定**：`firstHostStatus`——"取第一帧带信息的连接器状态，超时就放弃"
///   （原来写在设置页里，1.5 秒的期限没有测试）。这条留在能力里是因为它只依赖链路，
///   与界面无关。
public struct LinkGateway: Sendable {

    /// 连接器报来的一帧状态。
    public struct HostStatus: Sendable, Equatable {
        public var online: Bool
        public var info: JSONValue?

        public init(online: Bool, info: JSONValue?) {
            self.online = online
            self.info = info
        }
    }

    private let clientProvider: @MainActor @Sendable () -> DSHClient?
    private let statusStreamProvider: @MainActor @Sendable () async -> AsyncStream<HostStatus>

    public init(clientProvider: @escaping @MainActor @Sendable () -> DSHClient?,
                statusStreamProvider: @escaping @MainActor @Sendable () async -> AsyncStream<HostStatus> = {
                    AsyncStream { $0.finish() }
                }) {
        self.clientProvider = clientProvider
        self.statusStreamProvider = statusStreamProvider
    }

    /// 现在有没有可用的链路。
    @MainActor public var isConnected: Bool { clientProvider() != nil }

    /// 这条链路是不是经中转（设置页要显示"中转 / 直连"）。
    ///
    /// 判据在库里（`LinkCarrier` 是本包的类型），App 不必知道 carrier 是什么。
    @MainActor public var isRelay: Bool { clientProvider()?.carrier is LinkCarrier }

    // MARK: - 事件

    /// 会话事件流。没有链路时返回一个立刻结束的流（订阅方按"断了"处理）。
    @MainActor public func hostEvents() async -> AsyncThrowingStream<HostEvent, any Error> {
        guard let client = clientProvider() else {
            return AsyncThrowingStream { $0.finish() }
        }
        return await client.hostEvents()
    }

    /// 回答一条等待中的提示（问题/授权）。
    @MainActor public func answer(_ result: EventAnswer) async throws {
        guard let client = clientProvider() else { throw DSHTransportError.carrierClosed }
        try await client.answer(result)
    }

    // MARK: - 会话

    /// 会话列表（连接器支持精简摘要时走精简版，失败自动回退）。
    @MainActor
    public func sessions() async throws -> SessionListValue {
        guard let client = clientProvider() else { throw DSHTransportError.carrierClosed }
        return try await client.sessions()
    }

    /// 归档 / 取消归档，返回宿主给出的归档集合。
    @MainActor
    public func archiveSession(_ sessionId: String, archived: Bool = true) async throws -> [String] {
        guard let client = clientProvider() else { throw DSHTransportError.carrierClosed }
        return try await client.archiveSession(sessionId, archived: archived)
    }

    /// 注册（或解析）一个工作区目录，返回它的身份。
    @MainActor
    public func createWorkspace(path: String) async throws -> WorkspaceCreateValue {
        guard let client = clientProvider() else { throw DSHTransportError.carrierClosed }
        return try await client.createWorkspace(path: path)
    }

    /// 撤掉一个刚注册、但后续失败的工作区（失败路径的清理）。
    @MainActor
    public func deleteWorkspace(id: String) async throws {
        guard let client = clientProvider() else { throw DSHTransportError.carrierClosed }
        try await client.deleteWorkspace(id: id)
    }

    /// 建会话。
    @MainActor
    public func createSession(_ request: SessionCreateRequest) async throws -> JSONValue {
        guard let client = clientProvider() else { throw DSHTransportError.carrierClosed }
        return try await client.createSession(request)
    }

    // MARK: - 文件下载

    /// 从能力造一个文件下载器（没有链路时返回 nil）。
    ///
    /// 下载器在包内构造（它直接持 `DSHClient`），App 只拿到对象、不碰 client。
    @MainActor
    public func fileDownloader(pacing: Duration = .milliseconds(50),
                              retries: Int = WorkspaceFileDownloader.windowRetries)
        -> WorkspaceFileDownloader? {
        guard let client = clientValue else { return nil }
        return WorkspaceFileDownloader(client: client, pacing: pacing, retries: retries)
    }

    // MARK: - 包内用

    /// 供**包内**（`MessageLayer` 的取页/发送闭包）取原始 client。
    ///
    /// 故意不是 `public`：App 拿不到它，所以"产品路径直接用 DSHClient"在类型层面就被挡住了；
    /// 包内的数据层仍然需要它（`historyWindow` / `prompt` 等方法面很宽，不值得逐个转发）。
    @MainActor
    var clientValue: DSHClient? { clientProvider() }

    // MARK: - 工作区

    /// 宿主的 workspace 列表基线。
    @MainActor public func workspaces(timeout: Duration = .seconds(20)) async throws -> WorkspaceBaseline {
        guard let client = clientProvider() else { throw DSHTransportError.carrierClosed }
        return try await client.workspaces(timeout: timeout)
    }

    /// 列一个工作区目录。
    @MainActor public func workspaceFiles(scopeId: String, path: String) async throws -> JSONValue {
        guard let client = clientProvider() else { throw DSHTransportError.carrierClosed }
        return try await client.workspaceFiles(scopeId: scopeId, path: path)
    }

    /// 读一个工作区文件（可带区间）。
    @MainActor public func workspaceFileRead(scopeId: String, path: String,
                                  range: JSONValue? = nil) async throws -> JSONValue {
        guard let client = clientProvider() else { throw DSHTransportError.carrierClosed }
        return try await client.workspaceFileRead(scopeId: scopeId, path: path, range: range)
    }

    // MARK: - 连接器状态

    /// 第一帧**带信息**的连接器状态，超过 `deadline` 就放弃。
    ///
    /// 为什么要期限：连接器安静时这一屏不该被它拖住（原来是设置页里写死的 1.5 秒，
    /// 现在这条判定有了测试）。没有链路、或期限内没有带信息的一帧，返回 `nil`。
    @MainActor public func firstHostStatus(deadline: Duration = .seconds(1.5)) async -> HostStatus? {
        let stream = await statusStreamProvider()
        return await withTaskGroup(of: HostStatus?.self) { group in
            group.addTask {
                for await status in stream where status.info != nil { return status }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
