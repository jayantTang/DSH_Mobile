import Foundation

/// 把 App 的诊断流水增量推给连接器（spec 020 的 FR-011）。
///
/// 为什么形状放在 DSHKit 而不是 App 目标：`_link/*` 这套方法都住在这里（`_link/hello`、
/// 历史读取……），协议形状只有一份实现才不会漂移；App 侧只负责"什么时候推"。
///
/// 契约：`specs/020-link-diagnostics/contracts/connector-diagnostics-method.md`
public struct LinkDiagnosticsClient: Encodable, Sendable {
    public let name: String?
    public let version: String?
    public let build: String?

    public init(name: String?, version: String?, build: String?) {
        self.name = name
        self.version = version
        self.build = build
    }
}

/// 一次推送的载荷。`events` 用 App 侧那份流水的结构（`seq/at/ms/kind/detail`）。
public struct LinkDiagnosticsRequest: Encodable, Sendable {
    public let protocolVersion: Int
    /// 上一批最后一条的序号；首批 0。
    public let since: Int
    /// 手机**自己的**时刻（epoch 毫秒）。连接器据此算手机与本机的时钟差——
    /// 这是三侧时间线里手机那一半唯一的锚点。
    public let sentAt: Int
    /// 因环满被挤掉、永远推不出来的条数（如实上报，别让它悄悄消失）。
    public let dropped: Int
    public let events: [LinkDiagnostics.Event]
    public let client: LinkDiagnosticsClient?

    public init(protocolVersion: Int = 1, since: Int, sentAt: Int, dropped: Int,
                events: [LinkDiagnostics.Event], client: LinkDiagnosticsClient? = nil) {
        self.protocolVersion = protocolVersion
        self.since = since
        self.sentAt = sentAt
        self.dropped = dropped
        self.events = events
        self.client = client
    }
}

/// 连接器的回答：收了几条、水位到哪。
public struct LinkDiagnosticsAck: Decodable, Sendable {
    public let accepted: Int
    public let lastSeq: Int
}

extension DSHClient {
    /// 推一批诊断事件。**调用方必须把失败当无事发生**：旧连接器会回
    /// `link/unsupported`，那是预期内的（契约 §4 第 1 条）。
    public func pushDiagnostics(_ request: LinkDiagnosticsRequest) async throws -> LinkDiagnosticsAck {
        try await carrier.unary(
            method: "_link/diagnostics",
            args: request,
            as: LinkDiagnosticsAck.self
        )
    }
}
