import Foundation

/// 从电脑取回的文件在手机上放在哪、按什么规则淘汰（spec 023 边界收敛：从 App 搬进 DSHKit）。
///
/// ## 为什么它属于 DSHKit
///
/// 这里全是**判定**：目录按"路径 + 版本"双重折叠（所以缓存自我失效，agent 改过的文件换了版本就落在
/// 新目录，昨天的副本永远不可能被当成今天的内容）、大小与宿主报的不一致就是残骸而不是命中、
/// `.part` 是"还没成为文件"的东西（发布靠 rename 原子完成）、超预算时丢最旧的且**跳过 `.part`**。
/// 这些判定以前在 App 里、**没有一条测试**；现在它们可以在这台 Mac 上 `swift test`。
///
/// ## 边界
///
/// **放哪个目录由 App 决定**（`root` 构造注入）。库不认识 `Caches` 也不读环境变量：
/// 原来那个 `DSH_WORKSPACE_CACHE_DIR` 覆盖在仓库里已经没有读者，是死配置，随这次搬迁删掉。
///
/// ## 线程安全
///
/// 无状态（只有 `root`），方法只碰文件系统；`Sendable` 值类型，谁持有谁用。
public struct WorkspaceFileCache: Sendable {

    /// 整个缓存可以占多少，超过就丢最旧的。
    ///
    /// 没有单文件上限（取一个 500 MB 的文件是正当需求），所以限制加在缓存整体上——否则它会
    /// 不知不觉涨到没人注意。
    public static let budgetBytes = 256 * 1024 * 1024

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - 位置

    /// 某个版本的那个文件该在哪，无论它在不在。
    public func destination(scopeId: String, path: String, version: String) -> URL {
        directory(scopeId: scopeId, path: path, version: version)
            .appendingPathComponent(Self.name(for: path))
    }

    /// 下载落在哪，直到它成为文件。
    ///
    /// 半到达的文件不是文件：它有自己的名字，谁也不能把它当完整文件打开。它**不再**是续传点
    /// （P-13c 起系统把未完成的字节持有为不透明的 `resumeData`），每次尝试都是整体替换而不是追加。
    /// 名字保留是因为"完成即 rename"仍然是发布原子的原因。
    public func partial(scopeId: String, path: String, version: String) -> URL {
        destination(scopeId: scopeId, path: path, version: version)
            .appendingPathExtension("part")
    }

    /// 把完成的 `.part` 发布成文件本身。
    ///
    /// rename 是"完成"原子的原因：无论进程怎么死，`.part` 都不会被当成完整文档。
    @discardableResult
    public func publish(scopeId: String, path: String, version: String) throws -> URL {
        let partial = partial(scopeId: scopeId, path: path, version: version)
        let complete = destination(scopeId: scopeId, path: path, version: version)
        let manager = FileManager.default
        try? manager.removeItem(at: complete)
        try manager.moveItem(at: partial, to: complete)
        return complete
    }

    /// 丢掉某个文件某个版本的副本（连同它的 `.part`）。
    ///
    /// 宿主报了新版本时调用：旧副本已经不是这个文件了，留着一个被取代的视频会白占几十 MB。
    public func discard(scopeId: String, path: String, version: String) {
        try? FileManager.default.removeItem(at: directory(scopeId: scopeId, path: path, version: version))
    }

    /// 丢掉 `.part`，给"这次下载算了"用。
    public func discardPartial(scopeId: String, path: String, version: String) {
        try? FileManager.default.removeItem(at: partial(scopeId: scopeId, path: path, version: version))
    }

    /// 恰好这个版本的缓存副本，且它确实是完整的。
    ///
    /// 大小与宿主报的不一致就不是命中，是中断写入留下的残骸：就地删掉，而不是当成文档打开。
    public func existing(scopeId: String, path: String, version: String,
                         bytes: Int?) -> (url: URL, bytes: Int)? {
        let url = destination(scopeId: scopeId, path: path, version: version)
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int
        else { return nil }
        if let bytes, size != bytes {
            try? manager.removeItem(at: url)
            return nil
        }
        return (url, size)
    }

    private func directory(scopeId: String, path: String, version: String) -> URL {
        root.appendingPathComponent("\(Self.digest("\(scopeId)~\(path)"))-\(Self.digest(version))",
                                    isDirectory: true)
    }

    // MARK: - 淘汰

    /// 丢掉最旧的文件，直到缓存回到预算内。
    ///
    /// 在下载之后调用而不是定时：缓存长大的时刻就是值得检查的时刻。
    ///
    /// **跳过 `.part`。** `.part` 是有人正在下的东西——可能是浏览器正在取、与刚完成的那个并行的
    /// 第二个文件。裁掉它会删掉一个活的前缀，随后 `publish()` 因为要 rename 的 `.part` 不见了而失败。
    /// 它既不计入总量也不进删除名单，所以半到达的文件也不会成为"某个完整文件因此活下来"的理由。
    public func trim(budget: Int = WorkspaceFileCache.budgetBytes) {
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        var files: [(url: URL, size: Int, modified: Date)] = []
        for directory in directories {
            let contents = (try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )) ?? []
            for file in contents where file.pathExtension != "part" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append((file, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
            }
        }

        var total = files.reduce(0) { $0 + $1.size }
        guard total > budget else { return }
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > budget else { break }
            try? manager.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// 清空缓存，给设置页的"清除"用。
    public func clear() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 纯函数

    /// 工作区里的一个文件路径，折叠成安全的最后一段。
    public static func name(for path: String) -> String {
        let base = (path as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(120))
    }

    /// 把一个字符串稳定地折成十六进制。
    ///
    /// 故意不用 `hashValue`：它每次启动都变，会把昨天的缓存目录变成孤儿。
    static func digest(_ value: String) -> String {
        let folded = value.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return String(folded, radix: 16)
    }
}
