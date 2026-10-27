import Foundation
import Observation
import RelayKit

/// 一条通知详情页的四种结局（设计 §M6.4）：加载中 / 正文 / 需要联网 + 重试 / 已不存在。
///
/// 状态归这个请求对象所有：视图只渲染 ``phase``，不自己另记"是否在加载"。
/// **取正文失败不标已读**——失败只能落到"需要联网查看"并给重试入口，不能因为网络
/// 失败把一条未读吃掉。
@MainActor
@Observable
public final class FeedbackNoticeDetail {

    public enum Phase: Sendable, Equatable {
        /// 正文在取（或重试刚发起）。
        case loading
        /// 正文已到手（来自缓存或这一次的按需路由），可以展示了。
        case ready
        /// 正文没取到、但还能重试：网络不通、服务端报错都走这里。
        case needsNetwork
        /// 服务端说这条通知不存在（或不属于这个账号）。
        case gone
    }

    public let noticeId: String
    public private(set) var phase: Phase = .loading

    private let center: FeedbackCenter

    public init(noticeId: String, center: FeedbackCenter = .shared) {
        self.noticeId = noticeId
        self.center = center
    }

    /// 打开详情。首次加载与"重试"是同一个入口，所以只有一条通路。
    public func load() async {
        guard phase != .ready else { return }
        // 正文已经在镜像里：直接展示并标已读（离线也算打开过）。
        if center.cachedNoticeBody(noticeId) != nil {
            phase = .ready
            await center.openNotice(noticeId)
            return
        }
        phase = .loading
        do {
            _ = try await center.fetchNotice(noticeId)
            phase = .ready
            // 只有在正文真拿到之后才标已读。
            await center.openNotice(noticeId)
        } catch let error as FeedbackClientError where error == .notFound {
            phase = .gone
        } catch {
            // 网络 / 服务器 / 限流都属于"还能再试"；这一支不标已读。
            phase = .needsNetwork
        }
    }
}
