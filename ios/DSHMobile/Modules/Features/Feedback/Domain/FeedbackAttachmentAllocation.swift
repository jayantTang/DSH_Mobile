import Foundation
import RelayKit

/// 一封信里每个逻辑附件最终要带哪些字节（**发送前的唯一计划**）。
///
/// 规则（设计 §5 A3）：先给每个逻辑附件预留主对象（图片预览 / 文件本体），再**按选择
/// 顺序**逐个尝试加入图片的原图（单个 ≤ `maxFileBytes`、累计 ≤ `maxTotalBytes`）；
/// 放不下的降级成「仅预览」。后面的小原图不会插队顶替前面放不下的。
///
/// 计划只保存"哪一项带原图"，字节本身仍在 ``FeedbackPreparedAttachment`` 里——同一个
/// 事实只有一份。
public struct FeedbackAttachmentPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let slot: Int
        /// 主对象（图片预览 / 文件本体）；永远带上。
        public let primary: FeedbackOutgoingAttachment
        /// 可选的另一份字节（图片原图）。
        public let original: FeedbackOutgoingAttachment?
        /// 这一项是否真的带原图（预算放不下就是 false，降级成「仅预览」）。
        public let includeOriginal: Bool

        public init(slot: Int, primary: FeedbackOutgoingAttachment,
                    original: FeedbackOutgoingAttachment? = nil, includeOriginal: Bool) {
            self.slot = slot
            self.primary = primary
            self.original = original
            self.includeOriginal = includeOriginal
        }

        /// 这一项实际要传的字节（按上传顺序：主对象在前，原图在后）。
        public var parts: [FeedbackOutgoingAttachment] {
            guard includeOriginal, let original else { return [primary] }
            return [primary, original]
        }

        public var byteSize: Int { parts.reduce(0) { $0 + $1.byteSize } }

        /// 有原图但被预算降级：列表/汇总里的「仅预览」。
        public var isPreviewOnly: Bool { original != nil && !includeOriginal }
    }

    public let items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    /// 主对象合计（预览 / 文件本体）：永远放得下，不受原图降级影响。
    public var previewBytes: Int { items.reduce(0) { $0 + $1.primary.byteSize } }

    /// 原图合计（只算真的带上的那些）。
    public var originalBytes: Int {
        items.reduce(0) { total, item in
            guard item.includeOriginal, let original = item.original else { return total }
            return total + original.byteSize
        }
    }

    public var totalBytes: Int { previewBytes + originalBytes }

    /// 被预算降级的槽位（按选择顺序）——「仅预览」的清单。
    public var degradedSlots: [Int] { items.filter(\.isPreviewOnly).map(\.slot) }

    public var degradedCount: Int { degradedSlots.count }

    /// 带原图的逻辑附件个数（「含高清 N」的唯一来源）。
    public var originalCount: Int { items.filter(\.includeOriginal).count }

    public var attachmentCount: Int { items.count }

    /// 汇总行读它（`FeedbackAttachmentSummary`）。
    public var flattened: [FeedbackPreparedAttachment] {
        items.map { FeedbackPreparedAttachment(slot: $0.slot, primary: $0.primary,
                                               original: $0.includeOriginal ? $0.original : nil) }
    }
}

/// "还能不能再加一个附件"：条数上限的**唯一**算法。
///
/// 写信页的预检（菜单、相册入口）与真正入列那一刻（``append``）都读它。多选文件时
/// 预检发生在解码之前，解码期间数量还会变，所以入列处必须再审一次（评审 P1-3）。
public enum FeedbackAttachmentSlotCapacity {
    public static func canAdd(currentCount: Int, limit: Int) -> Bool {
        currentCount >= 0 && limit > 0 && currentCount < limit
    }
}

/// 每封 24 MiB 的分配器：纯函数，输入准备结果与上限，输出计划。
///
/// 上限数字只从 ``FeedbackAttachmentLimits`` 读，不在这里写第二份。
public enum FeedbackAttachmentAllocation {
    public static func plan(_ items: [FeedbackPreparedAttachment],
                            limits: FeedbackAttachmentLimits) -> FeedbackAttachmentPlan {
        var used = items.reduce(0) { $0 + $1.primary.byteSize }     // 主对象先占额度
        var planned: [FeedbackAttachmentPlan.Item] = []
        // 一旦某一项的原图放不下，后面的原图**不再插队**：顺序就是用户的追加顺序，
        // 让小图顶替大图会让"为什么这张有高清、那张没有"变得无法解释（设计 §5 A3）。
        var originalsClosed = false
        for item in items {
            var include = false
            if !originalsClosed, let original = item.original {
                if original.byteSize <= limits.maxFileBytes,
                   used + original.byteSize <= limits.maxTotalBytes {
                    include = true
                    used += original.byteSize
                } else {
                    originalsClosed = true
                }
            }
            planned.append(FeedbackAttachmentPlan.Item(slot: item.slot, primary: item.primary,
                                                      original: item.original,
                                                      includeOriginal: include))
        }
        return FeedbackAttachmentPlan(items: planned)
    }
}

/// 写信页附件区末尾那一行汇总的数字与文案（设计 §5 A4）。
///
/// 数字全部从计划派生，不另存副本；文案走本地化键（中文即键），en/zh-Hans 各一条。
public struct FeedbackAttachmentSummary: Sendable, Equatable {
    public let attachmentCount: Int
    public let highDefinitionCount: Int
    public let previewOnlyCount: Int
    public let totalBytes: Int

    public init(attachmentCount: Int, highDefinitionCount: Int,
                previewOnlyCount: Int, totalBytes: Int) {
        self.attachmentCount = attachmentCount
        self.highDefinitionCount = highDefinitionCount
        self.previewOnlyCount = previewOnlyCount
        self.totalBytes = totalBytes
    }

    public init(plan: FeedbackAttachmentPlan) {
        self.init(attachmentCount: plan.attachmentCount,
                  highDefinitionCount: plan.originalCount,
                  previewOnlyCount: plan.degradedCount,
                  totalBytes: plan.totalBytes)
    }

    /// `12.4`：一位小数、点号小数点（与附件大小的既有显示口径一致）。
    public var megabytesText: String {
        String(format: "%.1f", Double(totalBytes) / (1024 * 1024))
    }

    /// 例：`3 个附件 · 含高清 2 · 仅预览 1 · 合计 12.4 MiB`。
    public var text: String {
        var parts = [String(localized: "\(attachmentCount) 个附件")]
        if highDefinitionCount > 0 {
            parts.append(String(localized: "含高清 \(highDefinitionCount)"))
        }
        if previewOnlyCount > 0 {
            parts.append(String(localized: "仅预览 \(previewOnlyCount)"))
        }
        parts.append(String(localized: "合计 \(megabytesText) MiB"))
        return parts.joined(separator: " · ")
    }
}
