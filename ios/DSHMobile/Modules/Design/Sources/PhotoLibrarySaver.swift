import Foundation
#if os(iOS)
import Photos
import UIKit

/// 把一张图存进系统相册，并把"存不了"的原因说清楚。
///
/// 为什么不是一行 `UIImageWriteToSavedPhotosAlbum`：它不告诉调用方权限被拒、
/// 也不会失败回调（`nil` 的 completion 什么都不报）。用户点了保存、界面没反应，
/// 是本仓库反复出现的那类"看不见的失败"。这里显式请求 `.addOnly` 权限，
/// 未授权返回 `.denied`，界面据此提示去设置。
///
/// 用的是 `PHAssetCreationRequest.addResource(with: .photo, data:)` 而不是
/// `UIImage`：**原图要按字节保存**（HEIC 仍是 HEIC、JPEG 质量不变），
/// 转成 `UIImage` 再写回会隐式重编码，等于把原图换成了另一份图。
@MainActor
public enum PhotoLibrarySaver {
    public enum Outcome: Equatable, Sendable {
        case saved
        /// 用户拒绝或系统限制（家长控制等）。
        case denied
        case failed(String)
    }

    /// 存一份图片字节。
    ///
    /// `data` 必须是完整的图片文件字节；`creationRequestForAsset` 的 `addResource`
    /// 不接受任意二进制。
    public static func save(data: Data) async -> Outcome {
        guard !data.isEmpty else { return .failed(String(localized: "图片是空的")) }

        let status = await authorization()
        switch status {
        case .authorized, .limited:
            return await createAsset(data: data)
        case .notDetermined:
            return await createAsset(data: data)
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// 存一份解码后的图（预览没有文件字节时走这里；会编码成 JPEG）。
    public static func save(image: UIImage) async -> Outcome {
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            return .failed(String(localized: "保存失败"))
        }
        return await save(data: data)
    }

    /// 相册写入权限；只在 `.notDetermined` 时弹系统询问。
    public static func authorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// 真正落相册的那一步。
    ///
    /// **必须 `nonisolated`，闭包也必须显式 `@Sendable`**：`performChanges` 的
    /// 变更块由 Photos 在自己的事务队列上执行；如果它从 `@MainActor` 函数里继承
    /// 主执行器隔离，Swift 运行时在事务队列上会直接 trap（2026-11-15 仿真器实测：
    /// 保存原图时 App 以 SIGTRAP 崩溃，栈顶是 `_swift_task_checkIsolatedSwift`）。
    private nonisolated static func createAsset(data: Data) async -> Outcome {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } as @Sendable () -> Void) { success, error in
                if success {
                    continuation.resume(returning: .saved)
                } else {
                    continuation.resume(
                        returning: .failed(error?.localizedDescription ?? String(localized: "保存失败")))
                }
            }
        }
    }
}
#endif
