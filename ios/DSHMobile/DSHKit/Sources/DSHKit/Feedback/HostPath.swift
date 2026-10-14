import Foundation

/// 宿主目录路径的两条判定（spec 023 边界收敛：从 App 的 `DirectoryBrowserModel` 抽出）。
///
/// 目录浏览器只有两个地方真的在"判断路径"：能不能往上走、往上走是哪个目录。它们看起来简单，
/// 但边界不少（根目录、结尾斜杠、相对路径），而原来它们写在 `@Observable` 的模型里、没有测试。
public enum HostPath {

    /// 上一级目录；已经在最上层（或路径退化了）时返回 nil。
    ///
    /// 具体规则：先剥掉结尾多出来的斜杠（根目录本身的 `/` 不剥），再取上一级；
    /// 结果为空、或与自身相同，都算"没有上一级"。
    public static func parent(of path: String) -> String? {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parent = (trimmed as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != trimmed else { return nil }
        return parent
    }

    /// 能不能往上走。
    public static func canGoUp(from path: String?) -> Bool {
        guard let path else { return false }
        return parent(of: path) != nil
    }
}
