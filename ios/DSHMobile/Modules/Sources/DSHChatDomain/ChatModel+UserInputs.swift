import DSHKit
import Foundation

/// T040：「我问过的」的读侧——**只读本地** `MessageStore` 的 `record` 表。浏览走
/// `userInputRecords`（role='me' 且来源是用户本人），关键词走 `record_fts`
///（trigram，<3 字符由 store 降级 LIKE），全程零网络。
///
/// 未灌全（`session_state.user_inputs_synced_at` 为空，data-model v3 的完整性标记）
/// **不是**回退条件：本地已经有几条就先显示几条，由面板显示「同步中…」状态行。
/// 旧的「本地为空 / 未灌全 → 走连接器 sessionFind」岔路已删除——它只在非存在的
/// 合理场景里生效（连接器不支持 role filter、回填任务还没跑到），却养出两套结果
/// 口径与两套文案（spec 009「追加修订：加载状态不许静默」第 5 条）。
public extension ChatModel {

    /// 本会话的「我问过的」本地命中（按 seq 由近及远）。`query` 为空是浏览模式
    ///（全量列表），非空走 FTS5。
    ///
    /// 返回空数组有两种含义——本地库还没灌到（看 `userInputsSynced()`）、或确实没有
    /// 匹配——两者都由面板如实呈现，调用方**没有**第二条路可退。
    public func localUserInputHits(query: String) async -> [TranscriptSearchHit] {
        guard let store = messageLayer?.store,
              let scope = sessionScope,
              let sessionId = session?.sessionId
        else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries: [UserInputEntry]
        do {
            entries = needle.isEmpty
                ? try await store.userInputRecords(scope: scope)
                : try await store.searchUserInputRecords(scope: scope, query: needle)
        } catch {
            return []
        }
        return entries.filter { $0.sessionId == sessionId }
            .sorted { $0.record.event.seq > $1.record.event.seq }
            .compactMap { entry in
                let record = entry.record
                guard let snippet = Self.snippet(of: record), !snippet.isEmpty else { return nil }
                let range = Self.highlightRange(of: needle, in: snippet)
                // 合成身份（同连接器路径的窗口外命中）：行身份由 seq 承担，点中后
                // ChatView.jumpToHit 按 seq 走 .jump 区间判定水合上下文。
                return TranscriptSearchHit(
                    id: "seq-\(record.event.seq)", role: .me, snippet: snippet,
                    highlightStart: range?.0 ?? 0, highlightLength: range?.1 ?? 0,
                    seq: record.event.seq)
            }
    }

    /// 本会话的用户输入子集是否已灌全（`session_state.user_inputs_synced_at` 有值）。
    ///
    /// `false` 是一等状态，不是错误：面板照常显示本地已有的命中，并在顶部挂一行
    /// 「同步中…」。磁盘层缺位、会话未挂、从没灌过都是 `false`（此时本来也没有
    /// 可展示的本地数据），语义只有一个——"这份列表还不完整"。
    public func userInputsSynced() async -> Bool {
        guard let store = messageLayer?.store,
              let scope = sessionScope,
              let sessionId = session?.sessionId
        else { return false }
        return (try? await store.userInputsSyncedAt(scope: scope, sessionId: sessionId)) != nil
    }

    /// (a) 打开会话内搜索面板、切到「只看我的提问」时，把这个会话的用户输入按需灌上。
    ///
    /// 幂等 + 防重入：已灌全直接返回；正在灌则不重复发起（面板的 1.5 秒轮询会把它翻成完整）。
    /// 冷启动那条后台预热只覆盖首屏可见的十来个会话（见 `MessageLayer.warmupPageBudget`），
    /// 归档/冷门会话就靠这里补——A2 之后单会话实测 0.3–1.1 秒，用户感知是"转一下"。
    public func ensureUserInputsBackfilled() async {
        guard let store, let layer = messageLayer,
              let scope = sessionScope, let summary = session
        else { return }
        guard await userInputsSynced() == false else { return }
        guard !isBackfillingUserInputs else { return }
        isBackfillingUserInputs = true
        defer { isBackfillingUserInputs = false }
        let supported = store.supports(LinkHandshake.Capability.historyRoleFilter)
        await layer.backfillUserInput(
            scope: scope, sessionId: summary.sessionId, lastSeq: summary.asOfSeq,
            roleFilterSupported: supported)
    }

    /// 记录正文：data.text 优先，blocks 拼接兜底（与 MessageStore.snippet 同一约定）。
    /// 真实 user/message 的正文在 `data.content[]`（blocks 形态）——读错键会让
    /// 本地列表整列丢光只剩 live 尾巴的几条（T036 慢闸抓出）。
    private static func snippet(of record: SessionRecord) -> String? {
        let data = record.event.data
        if let text = data["text"]?.stringValue, !text.isEmpty {
            return String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
        }
        if let blocks = data["content"]?.arrayValue ?? data["blocks"]?.arrayValue {
            let joined = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: " ")
            if !joined.isEmpty {
                return String(joined.replacingOccurrences(of: "\n", with: " ").prefix(120))
            }
        }
        return nil
    }

    /// 关键词在片段里的首个大小写不敏感命中（字符偏移，同 TranscriptSearch 的约定）。
    private static func highlightRange(of needle: String, in snippet: String) -> (Int, Int)? {
        guard !needle.isEmpty,
              let range = snippet.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        return (snippet.distance(from: snippet.startIndex, to: range.lowerBound),
                snippet.distance(from: range.lowerBound, to: range.upperBound))
    }
}
