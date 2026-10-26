import DSHKit
import Foundation

/// 过程折叠的文案与判定（纯函数）。
///
/// 口径逐条对桌面客户端的 `TurnProcessNodeView`（轮次行）、`processTitle`
/// （分组行标题）、`RunningStatus`（深度求索行）与 `formatRunDuration`（时长）：
/// 设计 `20261025-过程折叠-对齐桌面` §2.1–§2.3。视图只负责排版，不再自己拼文案。
///
/// 放进领域层而不是视图层，是因为这些规则（取前 3 类、共享「已」前缀、
/// 失败与中断不写用时）都要能用单测钉住；视图里的 `#if os(iOS)` 代码在
/// `swift test` 里跑不到。
public enum ProcessFoldText {

    // MARK: - 轮次行

    /// 结束原因里属于「被停止」的那几种。桌面只判 `aborted` / `interrupted`，
    /// 手机侧历史上还用过 `cancelled` / `canceled` 两个名字，一并按停止处理。
    public static func isStopped(_ endReason: String?) -> Bool {
        switch endReason {
        case "aborted", "interrupted", "cancelled", "canceled": return true
        default: return false
        }
    }

    /// 结束原因里属于「失败」的那几种。
    public static func isFailed(_ endReason: String?) -> Bool {
        switch endReason {
        case "error", "failed": return true
        default: return false
        }
    }

    /// 轮次行文案：`已完成，用时 1分39秒` / `已完成` / `处理失败` / `已停止`。
    ///
    /// 停止与失败都不写用时（桌面 `duration = stopped || error ? undefined : …`）；
    /// `max-steps` 按正常完成处理，不再有「达步数上限」这种状态。
    public static func turnLabel(endReason: String?, duration: TimeInterval?) -> String {
        if isStopped(endReason) { return String(localized: "已停止") }
        if isFailed(endReason) { return String(localized: "处理失败") }
        guard let duration, duration > 0 else { return String(localized: "已完成") }
        return String(format: String(localized: "已完成，用时 %@"), durationText(duration))
    }

    /// 时长文字：`18秒` / `1分39秒` / `1小时2分3秒`。
    ///
    /// 桌面把毫秒下限钳到 1000（`Math.max(1e3, ms)`），所以不足一秒写 `1秒`。
    public static func durationText(_ duration: TimeInterval) -> String {
        let total = max(1, Int(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: String(localized: "%lld小时%lld分%lld秒"), hours, minutes, seconds)
        }
        if total >= 60 {
            return String(format: String(localized: "%lld分%lld秒"), minutes, seconds)
        }
        return String(format: String(localized: "%lld秒"), seconds)
    }

    // MARK: - 分组行

    /// 分组行标题：按活动类别聚合，不带次数，取前三类。
    ///
    /// 逐条复刻桌面 `processTitle`（`lib/client.js:3852`）：
    /// - 一类：原样（`已读取文件`）；
    /// - 两类：`{第一类}并{第二类}`，**仅当两条都以「已」开头**时切掉第二类的「已」
    ///   （`已读取文件并搜索代码`），否则各自保留（`执行了命令并已读取文件`）；
    /// - 三类及以上：逗号连接，后续类别只做首字母小写、**不去前缀**，
    ///   超过三类以「等」结尾（`执行了命令，已读取文件，向用户提出了问题等`）；
    /// - 无活动：`已完成分析`。
    public static func groupTitle(_ activityCounts: [TimelineProcessActivity: Int]) -> String {
        let ranked = rankedActivities(activityCounts)
        let all = ranked.map(doneLabel)
        guard let first = all.first else { return String(localized: "已完成分析") }
        if all.count == 1 { return first }
        if all.count == 2 {
            let second = continuation(sharedPrefixStripped(all[1], first: first))
            return String(format: String(localized: "%@并%@"), first, second)
        }
        let rest = all.dropFirst().map(continuation)
        let joined = ([first] + rest.prefix(2)).prefix(3).map { $0 }
        if all.count > 3 {
            return String(format: String(localized: "%@，%@，%@等"), joined[0], joined[1], joined[2])
        }
        return String(format: String(localized: "%@，%@，%@"), joined[0], joined[1], joined[2])
    }

    /// 分组图标该用哪一类活动的图标：次数最多的那一类（同次数按类别固定顺序）。
    public static func topActivity(_ activityCounts: [TimelineProcessActivity: Int]) -> TimelineProcessActivity? {
        rankedActivities(activityCounts).first
    }

    /// 运行中的分组行标题：`正在运行命令 · go test ./internal/relay`。
    ///
    /// `activity == nil` 表示当前没有工具在跑（模型在思考），此时只有动词；
    /// `detail` 为空时不写分隔点（桌面 `detail === "" ? label : label + separator + detail`）。
    public static func runningGroupTitle(activity: TimelineProcessActivity?, detail: String) -> String {
        let label = runningLabel(activity)
        guard !detail.isEmpty else { return label }
        return String(format: String(localized: "%@ · %@"), label, detail)
    }

    // MARK: - 步骤卡（概要 v2）

    /// 步骤卡标题：思考步骤写「思考」，工具步骤保留工具本名（协议名，不翻译）。
    public static func stepTitle(kind: FoldSummaryV2.StepKind, name: String) -> String {
        kind == .reasoning ? String(localized: "思考") : name
    }

    /// 步骤卡右上角的一句话：输出大小 + 入口；失败只影响这一张卡。
    public static func stepOutputHint(bytes: Int?, body: ProcessStepBodyState?) -> String {
        if body == .tooLarge {
            return String(localized: "输出过大，无法在手机上展开")
        }
        if body == .failed {
            return String(localized: "输出加载失败 · 点按重试")
        }
        return String(format: String(localized: "输出 %@ · 点开查看"), byteCountText(bytes))
    }

    /// 思考步骤只写大小（没有「输出」这个概念）。
    public static func thinkingStepHint(bytes: Int?) -> String {
        String(format: String(localized: "思考 · %@"), byteCountText(bytes))
    }

    /// 字节数的可读写法：`900 B` / `12.3 KB` / `1.2 MB`。
    ///
    /// 用 1024 进制（与服务端的 UTF-8 字节数对得上），只保留一位小数；
    /// 未知大小写 `—`，不编一个 0。
    public static func byteCountText(_ bytes: Int?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        if bytes < 1024 { return "\(bytes) B" }
        let kilobytes = Double(bytes) / 1024
        if kilobytes < 1024 {
            return String(format: "%.1f KB", kilobytes)
        }
        return String(format: "%.1f MB", kilobytes / 1024)
    }

    // MARK: - 深度求索行

    /// 运行行计时刷新间隔（秒）。与桌面一致，1 秒一次；只重算这一行的文本，
    /// 不改模型、不重建列表。放在领域层是为了单测能钉住这个值。
    public static let runningRefresh: TimeInterval = 1

    /// 底部运行行：`深度求索中，用时 12秒 ···`。
    public static func deepDivingText(elapsed: TimeInterval?) -> String {
        guard let elapsed, elapsed > 0 else { return String(localized: "深度求索中") }
        return String(format: String(localized: "深度求索中，用时 %@ ···"), durationText(elapsed))
    }

    // MARK: - 图标

    /// 活动类别对应的 SF Symbol 名（桌面 `PROCESS_ICONS`，手机用系统符号）。
    public static func activityIcon(_ activity: TimelineProcessActivity) -> String {
        switch activity {
        case .read: return "doc.text"
        case .write: return "square.and.pencil"
        case .edit: return "pencil.line"
        case .search: return "magnifyingglass"
        case .commands: return "terminal"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .web: return "globe"
        case .subagents: return "person.2"
        case .questions: return "questionmark.bubble"
        case .plan: return "checklist"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    /// 没有工具在跑（在思考）时的图标。
    public static let thinkingIcon = "sparkles"

    // MARK: - 私有

    /// 次数降序；同次数按枚举声明顺序，保证同一份数据每次得到同一句标题。
    private static func rankedActivities(_ activityCounts: [TimelineProcessActivity: Int])
        -> [TimelineProcessActivity] {
        let order = activityOrder()
        return activityCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return (order[lhs.key] ?? 0) < (order[rhs.key] ?? 0)
        }.map(\.key)
    }

    private static func activityOrder() -> [TimelineProcessActivity: Int] {
        var order: [TimelineProcessActivity: Int] = [:]
        for (index, activity) in TimelineProcessActivity.allCases.enumerated() {
            order[activity] = index
        }
        return order
    }

    /// 后续类别的连接形式：**只做首字母小写**（桌面 `charAt(0).toLowerCase() + slice(1)`）。
    ///
    /// 中文没有大小写，所以中文侧等于原样保留；「已」前缀不在这里处理，
    /// 只有两类分支会在双方都带前缀时切一次。
    private static func continuation(_ label: String) -> String {
        guard let head = label.first else { return label }
        return String(head).lowercased() + label.dropFirst()
    }

    /// 两类分支的共享前缀：first 与 second 都以「已」开头时，切掉 second 的那一次。
    ///
    /// 与桌面一致（`prefix !== "" && first.startsWith(prefix) && second.startsWith(prefix)`）。
    /// 英文侧前缀是空串，等价于不切。
    private static func sharedPrefixStripped(_ second: String, first: String) -> String {
        let prefix = String(localized: "已")
        guard !prefix.isEmpty, first.hasPrefix(prefix), second.hasPrefix(prefix) else { return second }
        return String(second.dropFirst(prefix.count))
    }

    private static func doneLabel(_ activity: TimelineProcessActivity) -> String {
        switch activity {
        case .read: return String(localized: "已读取文件")
        case .write: return String(localized: "已写入文件")
        case .edit: return String(localized: "修改了文件")
        case .search: return String(localized: "已搜索代码")
        case .commands: return String(localized: "执行了命令")
        case .code: return String(localized: "运行了代码")
        case .web: return String(localized: "已搜索网页")
        case .subagents: return String(localized: "已协调子智能体")
        case .questions: return String(localized: "向用户提出了问题")
        case .plan: return String(localized: "更新了计划")
        case .tools: return String(localized: "已调用工具")
        }
    }

    private static func runningLabel(_ activity: TimelineProcessActivity?) -> String {
        switch activity {
        case .read: return String(localized: "正在读取文件")
        case .write: return String(localized: "正在写入文件")
        case .edit: return String(localized: "正在编辑文件")
        case .search: return String(localized: "正在搜索代码")
        case .commands: return String(localized: "正在运行命令")
        case .code: return String(localized: "正在运行代码")
        case .web: return String(localized: "正在搜索网页")
        case .subagents: return String(localized: "正在协调子智能体")
        case .questions: return String(localized: "等待你的操作")
        case .plan: return String(localized: "正在更新计划")
        case .tools: return String(localized: "正在调用工具")
        case nil: return String(localized: "正在分析请求")
        }
    }
}
