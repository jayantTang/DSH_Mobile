import DSHKit
import Foundation

/// 上拉取页服务：实际状态机在 SessionPipeline，这里只做桥的转发与预算裁剪。
@MainActor
final class ChatPagingService {
    private unowned let model: ChatModel

    init(model: ChatModel) { self.model = model }

    private var pipelineBridge: ChatPipelineBridge? { model.pipelineBridge }
    private var timeline: ChatTimeline {
        get { model.timeline }
        set { model.timeline = newValue }
    }
    private func setOlderState(_ next: ChatModel.OlderPageState) { model.setOlderState(next) }


    func loadOlder() async {
        // 没有管道就没有"更早的页"可取：不请求、也不落失败（以前写成
        // 「尚未连接」，在没有管道的宿主/夹具里会凭空出现一条重试胶囊）。
        guard let bridge = pipelineBridge else { return }
        await bridge.loadOlder()
    }

    /// Keeps the in-memory window inside its budget.
    ///
    /// Two guards, both learned the hard way (2026-10-08, run 20261008-202231):
    ///
    /// * **Only while following the live tail.** Dropping rows above a reader who is
    ///   *reading* them shifts what they see (`List` keeps offsets, not visible
    ///   content — the trap `anchorAfterPrepend` exists for).
    /// * **Off by default until the P3 anchoring redesign.** Shrinking `items` while a
    ///   programmatic `scrollTo` is in flight crashes UIKit
    ///   (`_validateScrollingTargetIndexPath` → SIGABRT): the target index path no
    ///   longer exists. The view now debounces this call until the open-pin sequence
    ///   is done, but the whole interaction belongs with T045 (anchor once, after the
    ///   content settles). Until then the only way to exercise it is the DEBUG
    ///   `-DSHProbeWindowRows` flag, which is what case 47 uses.
    func trimWindowIfNeeded(readerIsFollowing: Bool) {
        #if DEBUG
        guard ChatProbe.shared.windowRows != nil else { return }
        #else
        return
        #endif
        guard readerIsFollowing else { return }
        // 上限策略同样在 DSHKit（`TranscriptWindowPlanner.rowsToDrop(rowCount:limit:)`）：
        // 这里只取"该丢几行"，丢的动作交给下面的 `timeline.dropOldestRows`。
        let excess = TranscriptWindowPlanner.rowsToDrop(
            rowCount: timeline.items.count, limit: ChatModel.windowLimitRows)
        guard excess > 0 else { return }
        let dropped = timeline.dropOldestRows(excess)
        guard dropped > 0 else { return }
        ChatProbe.shared.probeNote?("window.trimmed", [
            "dropped": String(dropped), "items": String(timeline.items.count),
            "oldest": String(timeline.firstSeq ?? -1),
        ], true)
    }

    /// Retries the page the reader is still waiting for (the top retry bar).
    func retryOlder() async {
        setOlderState(.idle)
        await loadOlder()
    }
}
