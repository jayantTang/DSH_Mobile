// 由 `npm run gen:host-baseline` 生成，不要手改。
// 来源：docs/relay-contract.json 的 hostBaseline.dshVersion
// 一致性：npm run check:contracts（第 ⑦ 段）

import Foundation

/// 主机（电脑端 DSH）的版本基线。
///
/// 低于它的主机连上来时，App 给一条可关闭的提示——**只提示，不阻断连接**。
/// 基线的真值与理由写在 `docs/relay-contract.json`。
enum HostBaseline {
    /// 这个版本及以上的主机视为满足基线。
    static let dshVersion = "0.1.5-rc.3"
}
