import Foundation

/// 截图用的「演示模式」。
///
/// 只有截图那一次运行会传 `-DSHDemoMode`（见 `test/cases/current/1x-*.steps`），
/// 正常启动永不生效，所以它不影响产品行为；而它解决的问题是真实的：
///
///   * **中转地址是部署方的资产**。它由运行中的 host 提供、在客户端渲染，
///     构建期换不掉——`relay.example.com` 那套占位符机制对它无能为力。
///   * **电脑名与家目录是个人信息**。设置页、连接页都会显示它们。
///
/// 因此凡是会被拍进图片的对外信息，都要经过这里换成占位符。放在一个文件里，
/// 是为了不再出现「设置页脱敏了、连接页忘了」这种情况（第一次拍上架截图就是）。
public enum DemoMode {
    /// 是否处于演示模式（由启动参数决定）。
    ///
    /// **Release 里恒为 false**：这个钩子只在截图那一次运行传，发布产物不该认得它。
    /// 调用点不用加门——`maskedEndpoint` / `maskedHostName` 在 `isOn == false` 时
    /// 原样返回，行为等价。
    public static var isOn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-DSHDemoMode")
        #else
        false
        #endif
    }

    /// 主目录的占位符。
    public static let homePlaceholder = "/Users/you"

    /// 中转地址的占位符，保留「· 中转」这类后缀。
    public static func maskedEndpoint(_ endpoint: String) -> String {
        guard isOn else { return endpoint }
        // 后缀同样要本地化：演示模式拍出来的英文截图里也不该留中文（`中转` 在表里）。
        let relay = String(localized: "中转")
        return endpoint.contains("·") ? "relay.example.com · \(relay)" : "relay.example.com"
    }

    /// 本机名（电脑名）的占位符。
    public static func maskedHostName(_ name: String) -> String {
        isOn ? "My Mac" : name
    }
}
