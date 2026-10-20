#if DEBUG
import Foundation

/// 自动化/诊断工具驱动输入框所需的**最小能力**（spec 024 / FR-005）。
///
/// 为什么要有它：`ViewportProbe.runTyping` 原来直接收 `ChatModel`，于是"基础设施"目录里出现了
/// 对业务类型的持有关系——`npm run arch` 里那条 `Support → Features/Chat` 反向边就是它。
/// 改成端口之后，工具只认这三个动作，具体对象由调用方（会话页）在调用点构造。
///
/// 端口本身住在基础设施层（而不是工具目录）：否则界面为了构造它就要反向依赖调试工具。
/// `#if DEBUG`：它在发布构建里没有消费者，不该编进去。
public struct TypingTarget {
    /// 这一轮是否正在流式流入（探针要等它真的开始，否则"边流入边打字"那条组合没被测到）。
    public var isRunning: () -> Bool
    /// 当前输入框内容。
    public var draft: () -> String
    /// 写回输入框内容。
    public var setDraft: (String) -> Void

    public init(isRunning: @escaping () -> Bool, draft: @escaping () -> String, setDraft: @escaping (String) -> Void) {
        self.isRunning = isRunning
        self.draft = draft
        self.setDraft = setDraft
    }
}
#endif
