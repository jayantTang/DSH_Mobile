import CoreGraphics
import Foundation

/// 过程区「状态未确认」的占位行（设计 `20261027-折叠抖动-方案A.md` M7 / A4）。
///
/// 为什么需要它：尾轮边界不是数据层事实之前，"这一轮到底跑没跑完"只能靠「窗口里
/// 恰好有没有边界行」推断；推断不出来时投影把那一段的**原始过程行整段铺开**，
/// 于是首帧行高集合与后续不一致，形态必然跳一次。
///
/// 现在的纪律：边界未知时**只输出这一行**，固定高度 44pt（与缺口行同一条纪律：
/// 首帧不许「先占位后变高」）。三态都由模型写，投影只搬运。
public struct TimelineProcessPlaceholder: Sendable, Equatable {

    /// 占位行的三态。四种结局（成功由行消失表达）都要落到可见状态：
    /// `.unresolved` 静置等读者重试，`.resolving` 是读者已经点过、有上限，
    /// `.failed` 是终态且可再试——不存在「看起来还在加载」。
    public enum State: Equatable, Sendable {
        /// 状态还没确认（静置；可重试）。
        case unresolved
        /// 读者已点重试，正在确认（有 5 s 上限，见阶段二的 `retryTailBoundary`）。
        case resolving
        /// 读库失败 / 缺段 / 超时（可重试）。
        case failed(TailBoundaryFailure)
    }

    /// 失败的三条具体原因：文案与重试语义各不相同，不能压成一个「失败」。
    public enum TailBoundaryFailure: Equatable, Sendable {
        /// 读本地库抛错。
        case read
        /// 本地区间集在下方有洞，补读不猜。
        case hole
        /// 补读超过时间上限。
        case timeout
    }

    /// 这一轮（边界未知的那个尾轮）的轮次号；推不出来时为 0。
    public let turn: Int
    /// 这一轮的起点 seq：行的 `seq` 取它，参与裁剪前缀比较但不冒充数据行。
    public let startSeq: Int
    public var state: State

    /// 固定高度：占位行不得因为状态变化改变高度。
    public static let height: CGFloat = 44

    public init(turn: Int, startSeq: Int, state: State = .unresolved) {
        self.turn = turn
        self.startSeq = startSeq
        self.state = state
    }

    /// 行身份：由轮次起点派生，重折前后稳定（同一个窗口折两次不得出现两行）。
    public var id: String { Self.rowID(startSeq: startSeq) }

    public static func rowID(startSeq: Int) -> String { "process-unknown:\(startSeq)" }

    /// 换状态：身份与高度都不动（列表宿主靠签名变化重载内容）。
    public func with(state: State) -> TimelineProcessPlaceholder {
        var next = self
        next.state = state
        return next
    }

    /// 这一行的时间线形态。
    public var item: TimelineItem {
        TimelineItem(id: id, kind: .processPlaceholder(self), seq: startSeq)
    }
}
