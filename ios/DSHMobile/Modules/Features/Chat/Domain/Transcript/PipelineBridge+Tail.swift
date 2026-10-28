import DSHKit
import Foundation

/// 桥在尾轮边界这一侧的最小接缝（设计 `20261027-折叠抖动-方案A.md` M5'-3）。
///
/// 为什么需要它：桥的会话把手是在订阅任务里**异步**取回来的（`subscribe()`）。
/// 首帧补读的前缀要在 `startPipelineSubscription` 之后立刻并进管道，那时把手多半
/// 还没回来——`absorb` 的 `guard let session` 会把这批记录**静默丢掉**，第二次
/// refold 就把首帧的行抹掉了（正是 M5'-3 要防的那一幕）。
extension ChatPipelineBridge {

    /// 把会话把手落实（幂等）。补读前缀前必须先调它。
    func prepareSession() async {
        guard session == nil else { return }
        session = await layer.session(for: ref)
    }
}
