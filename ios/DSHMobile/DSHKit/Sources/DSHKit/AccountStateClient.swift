import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 账户级状态的中转客户端（032）。
///
/// 存的是"一台设备改了、同账户其他设备要跟着变"的那几项：会话已读水位、角标水位、
/// 提醒开关、待回应已回答。**中转不解释值**，只保证 `updatedAt` 单调，所以合并规则
/// （已读取 `max`、开关后写覆盖）在调用方——见 ``AccountStateMerger``。
///
/// 与 `RelayFeedbackClient` 同一个形状：真实 `URLSession`、Bearer 设备令牌、
/// 路径前缀跟着中转配置走。
public struct AccountStateClient: Sendable {

    /// 一条状态。`value` 是任意 JSON（`.object` / `.array` / 标量都行）。
    public struct Entry: Sendable, Equatable {
        public let key: String
        public let value: JSONValue
        /// 毫秒。由调用方给：中转只比较大小，**只前进不后退**。
        public let updatedAt: Int

        public init(key: String, value: JSONValue, updatedAt: Int) {
            self.key = key
            self.value = value
            self.updatedAt = updatedAt
        }
    }

    /// 写入结果。`applied` 是真正被接受的 key（更旧的那些不在里面）。
    public struct WriteResult: Sendable, Equatable {
        public let applied: [String]
        public let entries: [String: Entry]
    }

    public enum Failure: Error, Equatable {
        /// 没有可用的中转地址（未配对、档案缺失）。
        case unreachable(String)
        case http(status: Int, body: String)
        case malformed(String)
    }

    private let relayURL: URL
    private let deviceToken: String
    private let session: URLSession

    public init(relayURL: URL, deviceToken: String, session: URLSession? = nil) {
        self.relayURL = relayURL
        self.deviceToken = deviceToken
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    /// 拉指定 key（`keys` 为空就是全部）。
    public func fetch(keys: [String] = []) async throws -> [String: Entry] {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        components?.path = LinkConfiguration.appending(path: "/account/state", to: relayURL)
        if !keys.isEmpty {
            components?.queryItems = [URLQueryItem(name: "keys", value: keys.joined(separator: ","))]
        } else {
            components?.query = nil
        }
        guard let url = components?.url else { throw Failure.unreachable("中转地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")

        struct Answer: Decodable {
            let ok: Bool?
            let entries: [String: Wire]?
            let error: DSHRPCFailure?

            struct Wire: Decodable {
                let value: JSONValue?
                let updatedAt: Int?
                let updatedByDeviceId: String?
            }
        }
        let answer = try await send(request, as: Answer.self)
        return (answer.entries ?? [:]).reduce(into: [:]) { result, pair in
            result[pair.key] = Entry(key: pair.key,
                                     value: pair.value.value ?? .null,
                                     updatedAt: pair.value.updatedAt ?? 0)
        }
    }

    /// 写一批（最多 64 条，与中转的上限一致）。返回真正被接受的 key。
    @discardableResult
    public func put(_ entries: [Entry]) async throws -> WriteResult {
        guard !entries.isEmpty else { return WriteResult(applied: [], entries: [:]) }
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        components?.path = LinkConfiguration.appending(path: "/account/state", to: relayURL)
        components?.query = nil
        guard let url = components?.url else { throw Failure.unreachable("中转地址无效") }

        struct Body: Encodable {
            struct Wire: Encodable {
                let key: String
                let value: JSONValue
                let updatedAt: Int
            }
            let entries: [Wire]
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(
            entries: entries.map { Body.Wire(key: $0.key, value: $0.value, updatedAt: $0.updatedAt) }))

        struct Answer: Decodable {
            let ok: Bool?
            let applied: [String]?
            let entries: [String: Stored]?
            let error: DSHRPCFailure?

            struct Stored: Decodable {
                let value: JSONValue?
                let updatedAt: Int?
            }
        }
        let answer = try await send(request, as: Answer.self)
        let stored = (answer.entries ?? [:]).reduce(into: [String: Entry]()) { result, pair in
            result[pair.key] = Entry(key: pair.key, value: pair.value.value ?? .null,
                                     updatedAt: pair.value.updatedAt ?? 0)
        }
        return WriteResult(applied: answer.applied ?? [], entries: stored)
    }

    private func send<Answer: Decodable>(_ request: URLRequest, as type: Answer.Type) async throws -> Answer {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformed("中转没有回 HTTP 响应")
        }
        if http.statusCode != 200 {
            // 错误信封里可能带 `error.message`，也带上原始 body 便于排查。
            if let failure = try? JSONDecoder().decode(AccountStateEnvelope.self, from: data),
               let error = failure.error {
                throw Failure.http(status: http.statusCode, body: error.message)
            }
            throw Failure.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw Failure.malformed("账户状态响应看不懂：\(error)")
        }
    }
}

/// 中转的错误信封（`{"ok":false,"error":{...}}`）。
private struct AccountStateEnvelope: Decodable {
    let ok: Bool?
    let error: DSHRPCFailure?
}

/// 合并规则：中转只保证"不后退"，**怎么合**在这里定，一处。
///
/// 两条规则覆盖了首批四个 key：
/// * **水位类**（已读、角标）取 `max`——两台设备各读各的，取大的那个才不会把已读抹掉；
/// * **开关类**取"更新的那次写"——用户最后一次点的意图为准。
///
/// 时间戳用**本地时钟**：设备之间有时差时，水位类靠取 max 天然容忍；开关类可能被
/// 快钟设备"钉住"，所以写入方在下发前用服务端时间兜一层（见 `AccountStateClock`）。
enum AccountStateMerger {

    /// 两个水位取较大的那个（逐会话逐项比较，不是整块覆盖）。
    static func maxWatermark(_ local: JSONValue?, _ remote: JSONValue?) -> JSONValue {
        guard let remote else { return local ?? .object([:]) }
        guard let local else { return remote }
        guard case .object(let localMap) = local, case .object(let remoteMap) = remote else {
            return remote
        }
        var merged = localMap
        for (key, remoteValue) in remoteMap {
            guard let localValue = merged[key] else { merged[key] = remoteValue; continue }
            if remoteValue.intValue ?? 0 > localValue.intValue ?? 0 { merged[key] = remoteValue }
        }
        return .object(merged)
    }

    /// 开关类：远端更新就用远端，否则保留本地。
    static func latest(_ local: AccountStateClient.Entry?,
                             _ remote: AccountStateClient.Entry?) -> AccountStateClient.Entry? {
        switch (local, remote) {
        case (nil, nil): return nil
        case (let local?, nil): return local
        case (nil, let remote?): return remote
        case (let local?, let remote?): return remote.updatedAt >= local.updatedAt ? remote : local
        }
    }
}
