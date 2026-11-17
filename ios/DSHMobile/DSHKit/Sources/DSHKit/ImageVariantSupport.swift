import Foundation

/// 连接器是否支持图片变体（`_link/imageCommit` 与 `_link/imageOriginal*`）。
///
/// 两个判据，按顺序看，**只有这一处判定**（IR-10 / SR-10.01）：
///
/// 1. 握手能力位 `image-variants`（连接器 0.8.2 起声明）；
/// 2. 能力位出现**之前**的版本：连接器从 0.8.1 起就有这两个方法，只是没带能力位。
///    只按能力位判定会让 0.8.1 的用户在 App 升级后白白退回内联预览——新版本已有的
///    功能不能因为缺一条后来才加的能力位而消失。
///
/// 版本读不出时不猜（`garbage`、空串、`git describe`）：按不支持处理，降级到内联
/// 预览——多传一份内联字节，好过把一次 404 当成网络故障弹给用户。
public enum ImageVariantSupport {

    /// 能力位出现之前、但方法已存在的版本下界。
    public static let versionBaseline = "0.8.1"

    /// 能力位在 `docs/relay-contract.json` 的 `capabilities` 里。
    public static let capability = LinkHandshake.Capability.imageVariants

    public static func supported(capabilities: Set<String>, connectorVersion: String?) -> Bool {
        if capabilities.contains(capability) { return true }
        guard let version = connectorVersion, HostVersion.numericComponents(version) != nil else {
            return false
        }
        return !HostVersion.isOlder(version, than: versionBaseline)
    }
}
