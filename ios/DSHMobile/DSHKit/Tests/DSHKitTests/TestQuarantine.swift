import DSHKit
import Foundation

/// `test/.quarantine.json` 的读取口（与 UI 用例运行器读的是同一份名单：
/// `test/tools/context.mjs` 的 `quarantine()`）。
///
/// 为什么集成测试也要读它：本机真实数据里存在宿主**打不开**的会话（当前是 v0 格式、
/// 宿主的 v0→v1 迁移拒收的那批）。集成测试自己挑会话时不看名单，就会一直挑中它们——
/// 2026-10-16 实测：`LiveIntegrationTests` 取"历史最长"的那条，而本机历史最长的正是
/// 被隔离的 `session-9d676f2d…`，于是该文件每次运行都红在同一条上，真实的回归信号被淹没。
///
/// 名单是**本机文件**（已 gitignore）：目录路径含家目录，写进被跟踪的文件会同时违反
/// "真值不出本机"与 `check:secrets`。文件缺失或读不动时按"没有隔离"处理——它是测试设施
/// 的配置，不该让"没拿到那份文件"变成测试失败。
struct TestQuarantine: Sendable {

    private struct Entry: Decodable {
        let reason: String?
        let sessions: [String]?
        let directories: [String]?
    }

    static let shared = TestQuarantine()

    private let sessions: Set<String>
    private let directories: [String]

    /// 名单里那段人工写的理由，用于跳过信息；空串表示没有隔离。
    let reason: String

    private init() {
        let file = Self.repoRoot.appendingPathComponent("test/.quarantine.json")
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else {
            sessions = []
            directories = []
            reason = ""
            return
        }
        sessions = Set(entry.sessions ?? [])
        directories = entry.directories ?? []
        reason = entry.reason ?? ""
    }

    /// 这条会话该不该被集成测试绕开。目录按**前缀**匹配，与运行器同一口径。
    func isQuarantined(_ session: SessionSummary) -> Bool {
        if sessions.contains(session.sessionId) { return true }
        guard let cwd = session.cwd, !cwd.isEmpty else { return false }
        return directories.contains { cwd.hasPrefix($0) }
    }

    /// 从一串会话里滤掉被隔离的那些（各处选择口统一走这里）。
    func usable(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.filter { !isQuarantined($0) }
    }

    /// **依赖仓库布局**：`#filePath` 向上六级是仓库根（与 `LinkConfigurationTests`、
    /// `DLPContractTests` 同一做法）。把 DSHKit 单独拷出去时名单读不到，按"没有隔离"处理。
    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }
}
