import Foundation

/// 已经答过的待回应提示（032 的 `answeredPrompts`）。
///
/// 为什么需要一份**本机**台账：账户状态里的一个 key 对应的是一整块值（PUT 是整体替换），
/// 所以"我这台答了 p2"必须连同之前知道的 p1 一起推上去，否则 p1 会被覆盖掉。
///
/// 语义与 `SessionViewLog` 同构：
/// * 键是裸 `promptId`，合并取**最大值**（同一条被两台设备几乎同时答掉也不冲突）；
/// * 按 `scope`（中转 + 电脑）分开存：两台电脑的 promptId 不会串台；
/// * 有界（默认 64 条），先丢最旧的——这是"最近答过什么"的台账，不是审计日志。
public final class PromptAnswerLog {

    private let defaults: UserDefaults
    private var answeredAt: [String: Double]
    private var scope: String?

    private static let key = "prompts.answeredAt"
    private static let limit = 64

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.key) as? [String: Double]
        self.answeredAt = stored ?? [:]
    }

    /// 指向一台电脑（或没有，未连接时）。
    public func useScope(_ scope: String?) {
        self.scope = scope
    }

    public var hostScope: String? { scope }

    private func key(_ promptId: String) -> String {
        scope.map { "\($0)|\(promptId)" } ?? promptId
    }

    /// 记下"我在这台答了这条"。
    public func markAnswered(_ promptId: String, at stamp: Double = Date().timeIntervalSince1970 * 1000) {
        let target = key(promptId)
        if let existing = answeredAt[target], existing >= stamp { return }
        answeredAt[target] = stamp
        trim()
        persist()
    }

    /// 把远端读到的并进来（逐条取 max）。返回是否有变化。
    @discardableResult
    public func mergeRemote(answeredAt remote: [String: Double]) -> Bool {
        var changed = false
        for (promptId, stamp) in remote {
            let target = key(promptId)
            if let existing = answeredAt[target], existing >= stamp { continue }
            answeredAt[target] = stamp
            changed = true
        }
        guard changed else { return false }
        trim()
        persist()
        return true
    }

    /// 上传用的快照：只含当前这台电脑的条目，键是裸 `promptId`。
    public func accountSnapshot() -> [String: Double] {
        guard let scope else { return [:] }
        let prefix = "\(scope)|"
        return answeredAt.reduce(into: [:]) { result, pair in
            guard pair.key.hasPrefix(prefix) else { return }
            result[String(pair.key.dropFirst(prefix.count))] = pair.value
        }
    }

    /// 这条提示答过了吗（本机或账户里）。
    public func isAnswered(_ promptId: String) -> Bool {
        answeredAt[key(promptId)] != nil
    }

    private func trim() {
        guard answeredAt.count > Self.limit else { return }
        let oldest = answeredAt.sorted { $0.value < $1.value }.prefix(answeredAt.count - Self.limit)
        for (id, _) in oldest { answeredAt.removeValue(forKey: id) }
    }

    private func persist() {
        defaults.set(answeredAt, forKey: Self.key)
    }
}
