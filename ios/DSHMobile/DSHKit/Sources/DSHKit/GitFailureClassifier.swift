import Foundation

/// `git/*` 失败码的**语义分类**（spec 023 的 S3：纯判定下沉）。
///
/// ## 为什么单独抽出来
///
/// 这张表原来在 App 的 `GitModel.phase(for:)` 里，**语义判定与面向用户的文案混在同一个 switch**
/// 里，于是它既没有测试、也看不出"哪些码其实是同一情况"。连接器新增一个错误码时最容易出现的偏差，
/// 就是悄悄走 `default`、把宿主的原文当成通用失败——两个下游（状态与话术）都会跟着错。
///
/// 现在分工是：**语义在这里**（有单测），**文案在 App**（`check:i18n` 管着它们）。
public enum GitFailureKind: Sendable, Equatable {
    /// 目录不在 git 仓库里——正常状态，不是错误。
    case notARepository
    /// 仓库还没有提交——历史列表显示空，而不是报错。
    case emptyRepository
    /// 这台电脑上没有 git。
    case gitUnavailable
    /// 改动太大，不在手机上展开。
    case tooLarge
    /// git 命令超时（仓库很大时会发生）。
    case timedOut
    /// 电脑上的连接器还没有 git 桥（网关报"不认识这个方法"一类）。
    case unsupported
    /// 其它 git 侧失败：带上宿主给的说明。
    case message(String)
}

public enum GitFailureClassifier {

    /// 把 `git/*` 的码归成种类。
    ///
    /// - Returns: 认得的种类；**不认得的一律 `.message(message)`**（把宿主的原文透出去，
    ///   而不是粗暴归到某一个已知种类——那会把"未知失败"伪装成"已知情况"）。
    public static func classify(code: String, message: String) -> GitFailureKind {
        switch code {
        case "git/not-a-repo": return .notARepository
        case "git/no-commits": return .emptyRepository
        case "git/unavailable": return .gitUnavailable
        case "git/too-large": return .tooLarge
        case "git/timed-out": return .timedOut
        case "git/not-found", "git/bad-request": return .message(message)
        case "gateway/bad-response", "gateway/not-found", "unknown",
             "gateway/unknown-method", "host/unavailable":
            // 旧连接器把调用转给宿主机，宿主机从没听说过这个方法：那是"这份构建需要更新的连接器"，
            // 不是 git 的问题。
            return .unsupported
        default: return .message(message)
        }
    }

    /// 直接从错误里归类。
    ///
    /// - Returns: `DSHRPCFailure` 走码表；**其它错误返回 `nil`** —— 那是传输类失败
    ///   （"电脑不应答"不该被装扮成"不是仓库"），由调用方按传输错误处理。
    public static func classify(_ error: any Error) -> GitFailureKind? {
        guard let failure = error as? DSHRPCFailure else { return nil }
        return classify(code: failure.code, message: failure.message)
    }
}

/// `git log` 分页的合并规则（原来写在 App 的 `GitModel.loadLog` 里）。
///
/// 两条规则都很小，但都是**判定**而不是"取数"：reset 与续读的差别、以及"下一页从哪里开始"。
/// 抽出来的另一层价值：`loadLog` 里那段 `reset ? 0 : commits.count` 与 `reset ? page : commits + page`
/// 必须始终一致，分开写迟早会有一处漏改。
public enum GitLogPaging {

    /// 合并一页：`reset` 就整批换掉，否则接在后面。
    public static func merge(_ existing: [GitCommit], page: [GitCommit], reset: Bool) -> [GitCommit] {
        reset ? page : existing + page
    }

    /// 这一次该跳过多少条：`reset` 从头发，否则从已有的后面接。
    public static func skip(existing: [GitCommit], reset: Bool) -> Int {
        reset ? 0 : existing.count
    }
}
