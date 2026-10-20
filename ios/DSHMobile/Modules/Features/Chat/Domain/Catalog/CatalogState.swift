import DSHKit
import Foundation
import Observation

/// 会话的模型目录与权限档位。
///
/// 从 `ChatModel` 拆出的第二块：这些值只由 host 的 projection 与设置写入改变，
/// 和转写/网络/输入区没有关系。ChatModel 保留同名转发属性，UI 调用点不变。
@MainActor
@Observable
public final class CatalogState {

    public var catalog: ModelCatalog?
    /// 目录最近一次读取的时刻；`refreshCatalogIfStale` 用它判定是否还要再问 host。
    public var fetchedAt: Date?
    public var isSettingDefaultModel = false
    public var defaultModelError: String?
    public var currentSelection: ModelSelection?
    public var permissionOptions: [PermissionsProjection.Option] = []
    public var currentPermission: String?

    public init() {}

    /// 模型新建会话时用的默认值，由 host 的目录给出。
    public var defaultSelection: ModelSelection? { catalog?.default }

    /// 打开会话：用这一条的 projection 覆盖选择与权限。
    public func load(from summary: SessionSummary) {
        currentSelection = summary.projections?.values?.modelSelection?.next
            ?? summary.projections?.values?.modelSelection?.lastUsed
        permissionOptions = summary.projections?.values?.permissions?.options ?? []
        currentPermission = summary.projections?.values?.permissions?.currentValue
    }

    /// 关会话/换电脑：整体清空，避免把上一台的目录带到下一台。
    public func reset() {
        currentSelection = nil
        permissionOptions = []
        currentPermission = nil
    }

    /// 采纳一次目录读取结果。
    public func adopt(_ catalog: ModelCatalog, at date: Date = Date()) {
        self.catalog = catalog
        fetchedAt = date
    }
}
