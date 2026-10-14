import Foundation

/// 会话列表的**切分判定**（spec 023 的 S3c）：哪些会话上列表、怎么按宿主的 workspace 分配、
/// 子代理挂到谁名下、没归档到 workspace 的归到哪里。
///
/// ## 边界
///
/// * **排序不在这里**：分组与成员的排序早在 `SessionListOrder`（同目录）里，本类型只把"集合怎么切"
///   算出来，排序仍由调用方套 `SessionListOrder`。
/// * **文案不在这里**：目录兜底分组的空标题返回 `""`，由调用方换成用户看得懂的字（界面语言归 App）。
/// * **状态不在这里**：`regroup` 里那套"未看/看过"的判定依赖 App 侧的首次见到记录，不进本类型。
///
/// ## 为什么要抽
///
/// 这段判定原来整块住在 `SessionListModel.regroup()`（约 105 行），与 `@Observable` 状态、
/// 刷新节奏、落盘快照混在一个文件里，**一条测试都没有**。它决定"用户在列表上看到哪些行"，
/// 错一条就是"某个会话不见了"——正是最该有断言、也最容易在重构中被改坏的地方。
public enum SessionGrouping {

    /// 一个分组：宿主的 workspace，或（没有 workspace 列表时的）一个目录。
    public struct Group: Identifiable, Sendable, Equatable {
        public let id: String
        public let path: String
        /// 空字符串表示"未分组"，由调用方换成界面文案。
        public var title: String
        public var sessions: [SessionSummary]
        /// 子代理转写按父会话 id 挂在这里，不单独占行。
        public var children: [String: [SessionSummary]]

        public init(id: String, path: String, title: String,
                    sessions: [SessionSummary], children: [String: [SessionSummary]]) {
            self.id = id
            self.path = path
            self.title = title
            self.sessions = sessions
            self.children = children
        }
    }

    /// 切分结果。两组"分组"是**二选一**的两种口径，调用方按"有没有读到 workspace 列表"取用：
    /// `workspaceGroups` 非空表示宿主给了 workspace 列表；否则用 `directoryGroups` 兜底。
    public struct Partition: Sendable, Equatable {
        public let workspaceGroups: [Group]
        public let directoryGroups: [Group]
        /// 没归档进任何 workspace 的顶层会话 + 找不到父会话的子代理，**未排序**。
        public let loose: [SessionSummary]

        public var hasWorkspaces: Bool { !workspaceGroups.isEmpty }
    }

    /// 切分。
    ///
    /// - Parameters:
    ///   - sessions: 宿主报的全部会话（含归档、含子代理）。
    ///   - archivedIds: 被归档的会话 id（归档只是从列表上隐藏，不删）。
    ///   - workspaces: 宿主给的 workspace 列表，**顺序就是用户的顺序**。
    ///   - query: 搜索词；空串表示不过滤。
    ///   - currentSessionId: 当前打开的会话；`blank` 会话只有在它是当前会话时才上列表。
    ///   - lastCreatedSessionId: App 刚创建的会话；`blank` 但它是刚建的，也要能看见。
    /// 「这一条会不会出现在列表上」的**唯一**判据（分组与"已归档"那一区共用一份，
    /// 免得两处各写一遍 `blank` 规则）。
    ///
    /// `blank` 会话（宿主为每个"打开过又没用"的新会话留的那条）默认不上列表，
    /// 两个例外：它是当前打开的会话，或它是 App 刚创建的。
    public static func showsInList(_ session: SessionSummary,
                                   currentSessionId: String?,
                                   lastCreatedSessionId: String?) -> Bool {
        guard session.blank else { return true }
        return session.sessionId == currentSessionId || session.sessionId == lastCreatedSessionId
    }

    public static func partition(
        sessions: [SessionSummary],
        archivedIds: Set<String>,
        workspaces: [Workspace],
        query: String,
        currentSessionId: String?,
        lastCreatedSessionId: String?
    ) -> Partition {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()

        // 归档的不上列表（桌面端也这样）；从没跑过一轮的 `blank` 会话同样不上——
        // 宿主会为每个"打开过又没用"的新会话留一条，桌面端从不把它们列成行。
        let visible = sessions.filter { session in
            guard !archivedIds.contains(session.sessionId) else { return false }
            return showsInList(session, currentSessionId: currentSessionId,
                               lastCreatedSessionId: lastCreatedSessionId)
        }

        let filtered: [SessionSummary]
        if trimmed.isEmpty {
            filtered = visible
        } else {
            filtered = visible.filter { session in
                if session.displayTitle.lowercased().contains(trimmed) { return true }
                if let cwd = session.cwd, cwd.lowercased().contains(trimmed) { return true }
                if let objective = session.projections?.values?.goal?.goal?.objective,
                   objective.lowercased().contains(trimmed) {
                    return true
                }
                return false
            }
        }

        // 子代理转写要从"生出它的那个会话"进，不单独占行。
        var byParent: [String: [SessionSummary]] = [:]
        var topLevel: [SessionSummary] = []
        for session in filtered {
            if session.isSubagent, let parent = session.parentSessionId {
                byParent[parent, default: []].append(session)
            } else {
                topLevel.append(session)
            }
        }
        let byId = Dictionary(topLevel.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })

        // 完全按桌面端侧栏的口径分组：宿主的 workspace 列表，每个装着用户放进去的会话、按用户的顺序。
        // 按 cwd 派生分组（这里以前的做法）会造出用户从没建过的组，还会把桌面端收起来的会话摊出来。
        var assigned = Set<String>()
        var built: [Group] = []
        for workspace in workspaces {
            let members = workspace.sessionIds.compactMap { id -> SessionSummary? in
                guard let session = byId[id] else { return nil }
                assigned.insert(id)
                return session
            }
            guard !members.isEmpty else { continue }
            built.append(
                Group(id: workspace.workspaceId, path: workspace.path, title: workspace.title,
                      sessions: members, children: byParent)
            )
        }

        // 用户没归档进任何 workspace 的。桌面端把它折起来：那是参考资料，不是当前的工作。
        let unfiled = topLevel.filter { !assigned.contains($0.sessionId) }
        let orphans = byParent
            .filter { !byId.keys.contains($0.key) }
            .flatMap(\.value)

        // 从没读到过 workspace 列表：按目录分组，至少还能用（列表页会写明这是兜底）。
        let byDirectory = Dictionary(grouping: topLevel, by: { $0.cwd ?? "" })
            .map { path, sessions in
                Group(id: path.isEmpty ? "__none__" : path,
                      path: path,
                      // 空标题 = "未分组"，文案由调用方给。
                      title: path.isEmpty ? "" : (path as NSString).lastPathComponent,
                      sessions: sessions,
                      children: byParent)
            }

        return Partition(workspaceGroups: built,
                         directoryGroups: byDirectory,
                         loose: unfiled + orphans)
    }
}
