// 由 `npm run gen:connector-baseline` 生成，不要手改。
// 来源：docs/relay-contract.json 的 connectorBaseline.minVersion
// 一致性：npm run check:contracts（第 ⑦ 段）

import Foundation

/// 连接器（电脑端 `dsh-plugin-mobile-link`）的版本基线。
///
/// 比的是 `_link/hello` 报上来的**连接器版本**（`serverVersion`），**不是** DSH host 版本：
/// 两者命名空间不同，混用会让提示条永不出现（基线远低于线上连接器）或天天误报。
/// 低于它的连接器连上来时，App 给一条可关闭的提示——只提示，不阻断连接。
/// 真值与理由写在 `docs/relay-contract.json`。
enum ConnectorBaseline {
    /// 这个版本及以上的连接器视为满足基线。
    static let minVersion = "0.3.1"
}
