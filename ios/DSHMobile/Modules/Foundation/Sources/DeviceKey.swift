import Foundation

/// 这台 client 的持久身份（032）。
///
/// 为什么需要它：配对码改成"可以反复认领"之后，同一台手机重装 App 再配一次，如果每次都算
/// 一台新设备，一个账户 8 个名额会被同一台手机吃掉好几次（生产上已经有账户配到 7 台，
/// 其中不少就是重复配对留下的）。带上这个 key 回来，中转就**复用原来那台设备**、只换发一枚
/// 新 token——"换钥匙不换身份"。
///
/// 存在**钥匙串**里，不是 `UserDefaults`：卸载 App 不清钥匙串，所以重装能拿回同一个身份；
/// 而 `UserDefaults` 会随卸载一起消失，那样"重装不占名额"就落空了。
///
/// 与账号绑定：`account` 用"中转地址 + agentId"拼出来，换一台电脑配对就是另一个身份，
/// 两台电脑不会互相顶掉。
public enum DeviceKey {

    /// 中转对 `deviceKey` 的形状要求：8–128 个字符，字母数字加 `-`/`_`。
    /// 这里生成 `dk_` + 32 位十六进制，落在范围内且不可猜。
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return "dk_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 取这台 client 对某个中转/电脑组合的持久 key；没有就生成一枚并存好。
    ///
    /// 读失败（钥匙串不可用、模拟器异常）时返回 nil 而不是抛错：认领不该因为"拿不到 key"
    /// 而失败——最坏的结果只是这次按新设备算，与今天的行为一致。
    public static func current(for scope: String,
                               keychain: DeviceKeyStorage = DeviceKeyStorage()) -> String? {
        if let existing = keychain.read(scope), isValid(existing) { return existing }
        let fresh = generate()
        do {
            try keychain.write(fresh, scope)
        } catch {
            return nil
        }
        return fresh
    }

    /// 形状是否被中转接受（与 `relay-go/internal/store` 的 `ValidateDeviceKey` 同一口径）。
    public static func isValid(_ value: String) -> Bool {
        guard (8...128).contains(value.count) else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// 拼 scope：同一个中转上的不同电脑算不同身份，两台电脑不会互相顶掉。
    public static func scope(relayURL: URL, agentId: String) -> String {
        "deviceKey.\(relayURL.absoluteString)|\(agentId)"
    }
}

/// 钥匙串的薄封装，抽出来只为一件事：让用例能在没有真钥匙串的环境里跑
/// （iOS 的单元测试宿主没有签名身份，`SecItemAdd` 会回 `-34018`）。
public struct DeviceKeyStorage: Sendable {

    private let read: @Sendable (String) -> String?
    private let write: @Sendable (String, String) throws -> Void

    public init(read: (@Sendable (String) -> String?)? = nil,
                write: (@Sendable (String, String) throws -> Void)? = nil) {
        self.read = read ?? { scope in Keychain.get(scope) }
        self.write = write ?? { value, scope in try Keychain.set(value, for: scope) }
    }

    func read(_ scope: String) -> String? { read(scope) }

    func write(_ value: String, _ scope: String) throws { try write(value, scope) }
}
