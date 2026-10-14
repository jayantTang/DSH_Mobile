import Foundation

// 连接请求的 URL 解析（spec 024 / S1：从 App 的 Features/Connection 搬进协议层）。
//
// 为什么在库里：它是**纯解析**（Foundation 的 URLComponents + 一个值类型），却被基础设施
// （`ConnectionStore` 做中转地址归一化）和界面（扫码页、启动参数）同时使用。留在 App 的
// Features 下会让"基础设施 → 业务目录"这条反向依赖成立（`npm run arch` 的 4 模块环就是它
// 和探针各占一条）。放进协议层之后，双方都只依赖库，方向是单向的。
//
// 语义与搬迁前逐字一致，含 `#if DEBUG` 的自动化形状——发布构建解析不到它。

/// A connection request encoded as a URL.
///
/// This is the payload a QR code carries. The desktop client shows a code, the
/// phone scans it, and onboarding completes without anyone typing a token —
/// which is also the only realistic way to onboard someone who is not the
/// person running the server.
///
/// Two shapes are accepted:
///
/// - `dsh://pair?relay=https://relay.example&code=ABCD-1234`
/// - `dsh://direct?host=192.0.2.20&port=54499&token=<launchToken>`
public enum ConnectLink: Equatable {
    case pair(relay: URL, code: String)
    case direct(baseURL: URL, launchToken: String)
    #if DEBUG
    /// A relay link whose device credential has already been claimed.
    ///
    /// Only the automated run uses this shape. A pairing code is one-time, so
    /// whoever claims it is the only party that learns the device id — and the
    /// run needs that id to revoke the device when it finishes, which is what
    /// keeps simulator runs from leaving paired devices on the relay. The
    /// product's own pairing still trades the code (`case pair`).
    ///
    /// Debug only, and parsed only from a launch argument: a shipping build must
    /// not be steerable onto a stranger's relay by a link.
    case claimedRelay(relayURL: URL, agentId: String, deviceToken: String, name: String?)
    #endif

    /// Parses an incoming URL, returning nil for anything unrecognized.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "dsh" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // 查询项自己解，不用 `components.queryItems`：那套只做百分号解码，而链接是**表单编码**
        // 的（桌面端与测试台都用 `URLSearchParams` 生成），空格写作 `+`。用 `queryItems` 会得到
        // `Jayant+MacBook+Pro` 这种设备名（2026-10-14 在连接管理页实拍到）。
        let query = Self.formDecodedQuery(components)
        func value(_ name: String) -> String? {
            query[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // The action is carried either as the host or the path, so both
        // `dsh://pair?...` and `dsh:///pair?...` work.
        let action = (url.host() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()

        switch action {
        case "pair":
            guard let relayString = value("relay"), let relay = URL(string: relayString),
                  let normalized = Self.normalizedRelayURL(relay),
                  let code = value("code"), !code.isEmpty
            else { return nil }
            self = .pair(relay: normalized, code: code)

        case "direct":
            guard let host = value("host"), !host.isEmpty,
                  let token = value("token"), !token.isEmpty
            else { return nil }
            let port = value("port") ?? "54499"
            guard let baseURL = URL(string: "http://\(host):\(port)") else { return nil }
            self = .direct(baseURL: baseURL, launchToken: token)

        #if DEBUG
        case "relay":
            guard let relayString = value("relay"), let relay = URL(string: relayString),
                  let normalized = Self.normalizedRelayURL(relay),
                  let agentId = value("agent"), !agentId.isEmpty,
                  let token = value("token"), !token.isEmpty
            else { return nil }
            self = .claimedRelay(relayURL: normalized, agentId: agentId,
                                 deviceToken: token, name: value("name"))
        #endif

        default:
            return nil
        }
    }

    /// 按表单编码（`application/x-www-form-urlencoded`）解出查询项。
    ///
    /// 顺序不能反：**先**把 `+` 还原成空格，**再**做百分号解码。反过来的话真正的加号（`%2B`）
    /// 也会变成空格。重复的键取第一个（与 `queryItems` 的 `first` 语义一致）。
    static func formDecodedQuery(_ components: URLComponents) -> [String: String] {
        let raw = components.percentEncodedQuery ?? components.query ?? ""
        var values: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first else { continue }
            func decode(_ text: Substring) -> String {
                let spaced = text.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            let key = decode(first)
            if values[key] == nil {
                values[key] = parts.count > 1 ? decode(parts[1]) : ""
            }
        }
        return values
    }

    /// Stores a relay address in its HTTP form.
    ///
    /// The relay hands out its WebSocket origin (`wss://…`) because that is what
    /// the connector dials, but the phone also has to reach `/pair/claim` over
    /// HTTP. Normalising once here means the profile holds a single address that
    /// both paths derive from — `LinkConfiguration` maps it back to `wss` for
    /// the socket.
    public static func normalizedRelayURL(_ url: URL) -> URL? {
        LinkConfiguration.normalizedRelayURL(url)
    }

    /// The URL a QR code should encode for a relay pairing.
    public static func pairingURL(relay: URL, code: String) -> URL? {
        var components = URLComponents()
        components.scheme = "dsh"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "relay", value: relay.absoluteString),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url
    }
}
