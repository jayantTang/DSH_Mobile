import Foundation

/// 这份 App 是靠哪条路装到设备上的。
///
/// 存在的理由只有一个：**App 内那条「有新版本可安装」横幅只对 OTA 那条路成立**。
/// OTA 安装页发的是 Apple Development 签名 + development 描述文件的包，横幅指回同一个
/// 安装页，装上就是新版；TestFlight（以及 App Store）装的是苹果分发签名的包，设备不允许
/// 用开发签名的 OTA 包覆盖它 —— 点了横幅只会一路走到「请先删除应用」。
/// 2026-10-11 那条 TestFlight 反馈（"更新要求先删除原有的"）说的就是这件事。
public enum InstallChannel: String, Sendable {

    /// OTA 安装页发的包：包里有内嵌描述文件，development 签名。
    case overTheAir

    /// TestFlight 与 App Store 装法：苹果分发签名，包里的描述文件被剥掉，只留 App Store 收据。
    case appStore

    /// 仿真器，以及既没有描述文件也没有收据的场合。更新横幅不发。
    case development

    /// 先看收据再看描述文件：苹果分发签名的包一定带收据、一定不带内嵌描述文件，
    /// 收据这一票更权威。
    public static var current: InstallChannel {
        #if DEBUG
        if let forced = forcedByLaunchArgument { return forced }
        #endif
        if hasAppStoreReceipt { return .appStore }
        if hasEmbeddedProfile { return .overTheAir }
        return .development
    }

    /// 更新横幅的开关：只有 OTA 装法能靠这个横幅真的装上。
    public var acceptsInAppUpdate: Bool { self == .overTheAir }

    /// App Store 收据放在包内（TestFlight 那份的文件名是 `sandboxReceipt`）。
    private static var hasAppStoreReceipt: Bool {
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 内嵌的 development / ad-hoc 描述文件：App Store 分发时苹果重签，会把它剥掉。
    private static var hasEmbeddedProfile: Bool {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
    }

    #if DEBUG
    /// `-DSHInstallChannel overTheAir|appStore|development`。
    ///
    /// 仿真器里既没有描述文件也没有收据，判定永远是 `.development` —— 没有这个钩子就
    /// 截不到「横幅该出现」的那一屏，只能验一半。Release 构建里不存在这条代码路径。
    private static var forcedByLaunchArgument: InstallChannel? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHInstallChannel"),
              index + 1 < arguments.count
        else { return nil }
        return InstallChannel(rawValue: arguments[index + 1])
    }
    #endif
}
