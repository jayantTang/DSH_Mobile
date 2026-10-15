import DSHKit
import Foundation

/// 009 跟底两态与可见性兜底（tasks T017/T018/T019，spec 009「跟底两态」「可见性兜底」、
/// 「UI 刷新推导」场景 2/3/7）。
///
/// 状态机只有两个态（业界口径）：
/// - `atBottom`：距末尾 ≤ 48pt（绝对值）且非"用户手指向上拖动中"——新消息自动贴底，无提示；
/// - `reading`：已离开底部——绝不自动滚，新消息计未读，由「↓ 新消息」胶囊表达。
///
/// 迁移（全部收敛在这几个入口，视图只上报几何、不自己判态）：
/// - 几何上报（宿主 `onFollowGeometry`）：距离超线或向上拖动 → reading；贴线且没拖 → atBottom；
/// - 点胶囊 / 发送自己的消息 → 强制 atBottom（`noteWantsBottom`，发送是 spec 钦定例外）；
/// - 跳转 / 换窗口（`rebaseWindow`）→ 强制 reading（否则下一条增量会把命中行拽走，spec 场景 9）。
///
/// 打开会话是特例：首帧纪律（T012）要求贴底，`open()` 重置为 atBottom——
/// 「换窗口强制 reading」针对的是**阅读中的跳转**，不是冷进入。
public extension ChatModel {

    /// 贴底阈值（绝对值，spec「跟底两态」表：不用「1 行高」）。
    public static let followBottomThreshold: CGFloat = 48

    /// 宿主的滚动几何上报：距底距离（点）+ 用户手指向上拖动中。
    /// 这是 atBottom ⇄ reading 之间**唯一**的双向迁移来源（其余入口都是单向强制）。
    public func noteFollowGeometry(distance: CGFloat, draggingUp: Bool) {
        if distance <= Self.followBottomThreshold, !draggingUp {
            if followState != .atBottom {
                followState = .atBottom
                unreadWhileReading = 0
                ChatProbe.probeNote?("follow.state", ["to": "atBottom",
                                                    "distance": String(Int(distance))], true)
            }
        } else if followState != .reading {
            followState = .reading
            ChatProbe.probeNote?("follow.state", ["to": "reading",
                                                "distance": String(Int(distance))], true)
        }
    }

    /// 点胶囊 / 发送自己的消息 / 手动滚到底：回到跟底态并清未读。
    public func noteWantsBottom() {
        followState = .atBottom
        unreadWhileReading = 0
    }

    /// 跳转 / 换窗口（rebaseWindow / open 内的搜索重定窗）：强制阅读中。
    public func noteJumpToReading() {
        followState = .reading
    }

    /// 打开会话：回到默认跟底（冷进入贴底是 T012 的首帧纪律）。
    public func noteFollowResetForOpen() {
        followState = .atBottom
        unreadWhileReading = 0
    }

    /// 桥报"尾部来了 n 条新消息"：reading 期间计未读（atBottom 时读者看得见，不计）。
    public func noteTailArrivals(_ count: Int) {
        guard count > 0 else { return }
        ChatProbe.probeNote?("follow.tail", ["count": String(count),
                                           "state": followState.rawValue,
                                           "unread": String(unreadWhileReading)], true)
        guard followState == .reading else { return }
        unreadWhileReading += count
    }

    /// 「↓ 新消息」胶囊点击（T018）：一律滚到最新。
    ///
    /// 差值补齐走管道的 `records(in:, .userVisible)`——尾部缺口在拉取期间以合成
    /// 底部缺口行（spinner）表达，与顶部"向上拉"同一渲染机制；差值 > 5 页时
    /// 降级为直接跳最新页（.jump），中间段丢弃（spec 场景 7 的降级语义）。
    /// 滚动本身由视图在 await 之后做（宿主 `scrollToBottom`）。
    public func jumpToLatest() async {
        noteWantsBottom()
        guard let bridge = pipelineBridge else { return }
        isCatchingUpTail = true
        bridge.noteCatchUpPresentationChanged()
        defer {
            isCatchingUpTail = false
            bridge.noteCatchUpPresentationChanged()
        }
        // 先对一次 host 的 lastSeq（胶囊上的未读数可能落后于真实尾部）。
        await refreshSummary()
        guard let last = session?.asOfSeq, last > 0 else { return }
        await bridge.catchUp(toHost: last)
    }

    /// 可见性兜底（T019）：WSS 重连成功后与回前台各对一次 `lastSeq`，
    /// 有差即向管道拉尾部增量。幂等：一轮在飞时后到的调用直接返回
    /// （更细的"同页合并"由管道的 in-flight 页表把守）。
    public func syncTailWithHost(reason: String) async {
        guard pipelineBridge != nil, !tailSyncInFlight else { return }
        guard let client = store?.client, let current = session else { return }
        tailSyncInFlight = true
        defer { tailSyncInFlight = false }
        guard let value = try? await client.sessions(),
              let updated = value.items.first(where: { $0.sessionId == current.sessionId })
        else { return }
        let local = pipelineBridge?.localNewestSeq() ?? 0
        ChatProbe.probeNote?("tail.sync", [
            "reason": reason,
            "local": String(local),
            "host": String(updated.asOfSeq),
        ], true)
        await pipelineBridge?.catchUp(toHost: updated.asOfSeq)
    }
}
