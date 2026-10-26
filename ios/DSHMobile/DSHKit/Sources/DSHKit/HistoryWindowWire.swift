import Foundation

/// `_link/sessionWindow` 的线上形态（spec 016 的后续：应用层压缩）。
///
/// 未压缩时回包就是 `HistoryWindowValue` 本身；连接器被要求 `encoding: "deflate-raw"`
/// 时回同一个值包在 `{encoding, value(base64), rawBytes}` 信封里——与
/// `_link/sessionDigest` 一模一样的信封，解码也只有一份（`decodeEnvelope`）。
///
/// 为什么允许两种形态：能力是连接器声明的，但半路升级、老中转照转、调用方重复请求
/// 都可能让同一端同时见到两种回包。按字段识别比按版本猜安全。
public enum HistoryWindowWire {
    /// 连接器在 `_link/hello` 里声明：`_link/sessionWindow` 接受 `encoding`。
    public static let compressionCapability = "history-compression"
    /// 连接器在 `_link/hello` 里声明：`_link/sessionWindow` 接受 `fold: true`。
    public static let foldCapability = "history-fold-summary"
    /// 连接器在 `_link/hello` 里声明：接受 `fold: "summary"`（概要 v2，按整轮下发）。
    public static let summaryFoldCapability = "history-fold-summary-v2"
    /// 概要模式下每页取几轮（管道路径的取页粒度；`limit` 在 v2 里是轮数）。
    public static let summaryRangeTurns = 6
    /// 覆盖信息（已知为空 + 版本）。
    public static let coverageCapability = "history-coverage"

    public static func decode(_ raw: JSONValue,
                              limit: Int = 32 * 1024 * 1024) throws -> HistoryWindowValue {
        let data = try JSONEncoder().encode(raw)
        if case .object(let object) = raw, object["encoding"] != nil {
            let envelope = try JSONDecoder().decode(SessionDigestEnvelope.self, from: data)
            return try decodeEnvelope(envelope, as: HistoryWindowValue.self, limit: limit)
        }
        return try JSONDecoder().decode(HistoryWindowValue.self, from: data)
    }
}
