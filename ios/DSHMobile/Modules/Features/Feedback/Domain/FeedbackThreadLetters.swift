import Foundation
import RelayKit

/// 一封信在「我这一侧」的三条读法：**只认线程自己的 `mySide`**。
///
/// 团队账号既是团队又是用户，账号级的一个布尔表达不了（2026-10-27 设计 §2.4）。
/// 两栏方向、未读归属、回信入口各只有这一份实现，视图直接调；`teamPerspective`
/// 从 v2 起不再参与分类。
public extension FeedbackThread {

    /// 未读归哪一位作者：我这一侧的**对侧**。
    var incomingAuthor: FeedbackMessage.Author { resolvedSide.counterpart }

    /// 收件箱里那一封（对侧最近一封）。团队自己的信没有对侧来信，所以是 nil
    /// ——它不会出现在收件箱，也不产生未读。
    var incomingLetter: FeedbackMessage? { messages.last { $0.author == incomingAuthor } }

    /// 已发送里那一封（我这一侧最近一封）。
    var myLetter: FeedbackMessage? { messages.last { $0.author == resolvedSide.author } }

    /// 团队对用户来信的回信入口：只有我这一侧是团队时才有。
    var canReply: Bool { resolvedSide == .owner }

    /// 我方的署名：团队侧固定「DSH Mobile 团队」；用户侧只写「我」。
    ///
    /// 用户的机型不作为**自称**：那是在把人当设备（owner 2026-11-02）。机型只用于团队侧
    /// 区分"哪个用户的哪台设备"，体现在 ``counterpartyLine`` 里。
    var myLine: String {
        resolvedSide == .owner ? FeedbackIdentity.team : FeedbackIdentity.me
    }

    /// **这一封的收发人**（唯一口径）：列表行、详情抬头、历史段都调它，不许三处各拼一次。
    ///
    /// 发件人按**作者**判（我方 / 对方），收件人就是对侧；`message == nil`（线程还没有信）
    /// 时按"我这一侧最近一封"的视角给。
    func correspondence(for message: FeedbackMessage?) -> (from: String, to: String) {
        let mine = message.map { $0.author.rawValue == resolvedSide.author.rawValue } ?? true
        return mine ? (myLine, counterpartyLine) : (counterpartyLine, myLine)
    }

    /// 列表行与历史段用的一行式写法（`%@ → %@`，走插值键）。
    func correspondenceLine(for message: FeedbackMessage?) -> String {
        let parties = correspondence(for: message)
        return String(localized: "\(parties.from) → \(parties.to)")
    }

    /// 两栏行首的对方称谓：我这一侧是团队时是来信人，否则是团队。
    var counterpartyLine: String {
        resolvedSide == .owner
            ? (source?.displayLine ?? String(localized: "匿名来信"))
            : String(localized: "DSH Mobile 团队")
    }
}

/// 收发双方的固定署名（唯一口径）：列表行、卡片抬头、历史段与通知共用。
public enum FeedbackIdentity {
    /// 团队侧的署名。
    public static var team: String { String(localized: "DSH Mobile 团队") }
    /// 通知的发件人。
    public static var service: String { String(localized: "服务通知") }

    /// 本机用户的署名：只写「我」。机型属于设备，不作为人的称呼（owner 2026-11-02）。
    public static var me: String { String(localized: "我") }

    /// 通知的收发人：发件人固定「服务通知」，收件人是本机用户。
    public static var noticeParties: (from: String, to: String) { (service, me) }
}

/// 正文长度的双约束判定（字符 + UTF-8 字节）。
///
/// 值来自服务端下发的 ``RelayKit/FeedbackLimits``（缺失时退编译期默认），发送窗口与
/// 回信输入框走同一套：两边都不许各写一份"还剩多少字"的算术。
public enum FeedbackDraftLength {

    /// 先触顶的是哪一边；文案据此分两句（字符 vs 字节）。
    public enum Overflow: Sendable, Equatable {
        case none
        case characters
        case bytes
    }

    /// 剩余字符数（可能为负：调用方据此显示"已超出"）。
    public static func remaining(_ text: String, limits: FeedbackLimits) -> Int {
        limits.textChars - text.count
    }

    /// 字符与字节哪个先触顶。两边都超时按超出的比例判断，平手算字符。
    ///
    /// 例：4001 个汉字两边同时超（12003 B），算字符；3001 个 emoji 只是字节超，
    /// 算字节——用户看到的"还有字数"是字符口径，必须说得清是哪种限制。
    public static func overflow(_ text: String, limits: FeedbackLimits) -> Overflow {
        let charsOver = text.count > limits.textChars
        let bytesOver = text.utf8.count > limits.textBytes
        switch (charsOver, bytesOver) {
        case (false, false):
            return .none
        case (true, false):
            return .characters
        case (false, true):
            return .bytes
        case (true, true):
            let charRatio = Double(text.count) / Double(max(1, limits.textChars))
            let byteRatio = Double(text.utf8.count) / Double(max(1, limits.textBytes))
            return charRatio >= byteRatio ? .characters : .bytes
        }
    }

    /// 能不能发：非空白且两个上限都没触顶。
    public static func canSend(_ text: String, limits: FeedbackLimits) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && overflow(text, limits: limits) == .none
    }
}
