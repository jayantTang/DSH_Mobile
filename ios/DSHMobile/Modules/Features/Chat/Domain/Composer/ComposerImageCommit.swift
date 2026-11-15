import Foundation

/// 一张待发图片提交后的结果，只保留 prompt 需要的部分。
///
/// `usedInlineFallback` 表示旧连接器不支持图片变体：这张图回退成内联预览
/// （今天的行为），而不是丢图。
struct ComposerImageCommit: Equatable {
    let imageId: UUID
    /// 预览在 Host 上的收据（`.file(receiptId:)`）。
    let previewReceiptId: String?
    /// 超限/不可解码原图作为普通文件上传后的收据。
    let fileReceiptId: String?
    let usedInlineFallback: Bool

    static func inline(_ imageId: UUID) -> ComposerImageCommit {
        ComposerImageCommit(
            imageId: imageId, previewReceiptId: nil,
            fileReceiptId: nil, usedInlineFallback: true
        )
    }
}
