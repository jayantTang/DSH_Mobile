import Foundation

/// 部署相关的地址：构建时由 `Config.xcconfig`（本机可用被 gitignore 的
/// `Config.local.xcconfig` 覆盖）注入 Info.plist，这里只负责读出来。
///
/// 仓库里提交的是 `relay.example.com` 占位符，所以 clone 下来直接构建的 App
/// 默认连不上任何中转——这是故意的：中转地址属于部署方，不属于仓库。要连自己的
/// 中转，`cp ios/DSHMobile/Config.xcconfig ios/DSHMobile/Config.local.xcconfig`
/// 再填真实地址即可。
enum AppConfig {

    /// 读 Info.plist 里的地址；缺失、为空、没被 xcconfig 替换掉（仍是 `$(...)`）
    /// 或不是合法 URL 时退回占位符。
    private static func string(_ key: String, fallback: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.isEmpty,
              !raw.hasPrefix("$("),
              URL(string: raw) != nil
        else { return fallback }
        return raw
    }

    /// 中转基址，含路径前缀，例如 `https://relay.example.com/dsh-link`。
    static var relayURL: String {
        string("DSHRelayURL", fallback: "https://relay.example.com/dsh-link")
    }

    /// OTA 安装页发布的 `version.json`。
    static var updateFeed: String {
        string("DSHUpdateFeed", fallback: "https://relay.example.com/ios/version.json")
    }
}
