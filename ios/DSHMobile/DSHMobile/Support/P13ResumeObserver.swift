#if DEBUG
import Foundation

/// P-13 探针的观测面：一个**独立会话**的 delegate。
///
/// 为什么不让探针复用产品的 `RelaySessionDelegate`：那一个的职责是"把字节交给
/// waiter"，探针要的是"把这次请求真的发了什么记录下来"。两者混在一起，探针的
/// 观测就会依赖产品实现，答不出"iOS 认不认 206"这个独立问题。
///
/// 它记录的是 v3 §4.2 判据 ① 的证据：**第二次请求实际发出的 `Range` 头**。
@MainActor
enum P13ResumeObserver {
    static let token = "p13-probe"

    nonisolated(unsafe) static var bytesWritten = 0
    nonisolated(unsafe) static var totalBytesWritten = 0
    nonisolated(unsafe) static var lastRangeHeader: String?
    nonisolated(unsafe) static var lastURL: String?
    nonisolated(unsafe) static var lastError: String?
    /// Whether the error's `userInfo` carried `NSURLSessionDownloadTaskResumeData`.
    ///
    /// The second place resume data can appear, and the one a network drop
    /// produces. Checking only the `cancel(byProducingResumeData:)` callback
    /// would read "the system gave nothing" off a callback that simply is not
    /// the one this failure uses.
    nonisolated(unsafe) static var lastErrorHadResumeData = false
    nonisolated(unsafe) static var onFinish: ((URL?) -> Void)?
    nonisolated(unsafe) private static var watched: [Int: URLSessionTask] = [:]

    static func reset() {
        bytesWritten = 0
        totalBytesWritten = 0
        lastRangeHeader = nil
        lastURL = nil
        lastError = nil
        lastErrorHadResumeData = false
        onFinish = nil
        watched = [:]
    }

    static func watch(_ task: URLSessionTask) { watched[task.taskIdentifier] = task }

    /// The delegate itself. A plain `NSObject` so it can be a session delegate.
    final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            P13ResumeObserver.bytesWritten = Int(totalBytesWritten)
            P13ResumeObserver.totalBytesWritten = Int(totalBytesWritten)
            P13ResumeObserver.lastURL = downloadTask.originalRequest?.url?.absoluteString
            P13ResumeObserver.lastRangeHeader = downloadTask.originalRequest?
                .value(forHTTPHeaderField: "Range")
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // 系统在这个回调返回后就删掉临时文件，所以先搬到自己的容器里。
            let kept = FileManager.default.temporaryDirectory
                .appendingPathComponent("p13-attempt2-\(UUID().uuidString).bin")
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.moveItem(at: location, to: kept)
            P13ResumeObserver.onFinish?(kept)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            if let error {
                P13ResumeObserver.lastError = "\(error)"
                let info = (error as NSError).userInfo
                P13ResumeObserver.lastErrorHadResumeData =
                    info["NSURLSessionDownloadTaskResumeData"] != nil
                // 失败也要放行等待者，否则探针挂死。
                P13ResumeObserver.onFinish?(nil)
            }
        }
    }
}
#endif
