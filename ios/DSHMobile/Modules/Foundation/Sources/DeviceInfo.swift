import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 设备与应用信息（原 ConnectionStore 的三个 static，026 下沉到 Foundation）。
///
/// 纯平台事实：任何层都可读，不属于连接单元。
public enum DeviceInfo {
    /// 机型标识（如 iPhone16,2）。
    public static var deviceModel: String {
        #if canImport(UIKit)
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
        #else
        return "macOS"
        #endif
    }

    /// 展示用版本号："1.0 (1234)"。
    public static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// 设备名（配对时给对方看的名字）。
    public static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Device"
        #endif
    }

    /// 系统版本（反馈附带的技术信息）。
    public static var systemVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
