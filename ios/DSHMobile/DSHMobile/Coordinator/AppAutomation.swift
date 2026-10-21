import DSHKit
import Foundation

/// 启动自动化入口（仅 DEBUG 有效）。
///
/// 放在 Coordinator 里而不是 RootView 上：启动装配要读这两个开关，而 RootView 已经
/// 依赖 Coordinator；留在 RootView 会形成 App ↔ Coordinator 的组级环（arch v027 抓到）。
enum AppAutomation {

    #if DEBUG
    /// Reads a connection link passed on the command line.
    static func link() -> ConnectLink? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHConnectURL"),
              index + 1 < arguments.count,
              let url = URL(string: arguments[index + 1])
        else { return nil }
        return ConnectLink(url: url)
    }

    /// Keeps the app on the pairing screen instead of reconnecting on launch.
    static func showsOnboarding() -> Bool {
        CommandLine.arguments.contains("-DSHOnboarding")
    }
    #else
    static func link() -> ConnectLink? { nil }
    static func showsOnboarding() -> Bool { false }
    #endif
}
