import DSHKit
import Foundation

/// LinkService 的账户状态订阅实现：订阅者由 store 持有，跨 carrier 重连存活。
// MARK: - LinkService 协议符合
extension ConnectionStore: LinkService {
    /// 032：账户级状态推送的**稳定**订阅口。
    ///
    /// 为什么要经过 store 而不是直接订阅 carrier：一条链路一个 carrier，配对、重连、切档案
    /// 都会换新的，而旧 carrier 的流既不会结束也不会再来帧——订阅方就此永远沉默。
    /// 这里由 store 持有订阅者名单，每次装上新 carrier（`install`）就把帧源接过去。
    public func accountStateStream() async -> AsyncStream<[String]> {
        await MainActor.run {
            let id = UUID()
            let (stream, continuation) = AsyncStream<[String]>.makeStream()
            accountStateObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.accountStateObservers.removeValue(forKey: id) }
            }
            return stream
        }
    }

    /// 把帧源接到当前 carrier 上（`install` 每次装新 carrier 都调）。旧的那条先取消。
    @MainActor
    func rewireAccountStateFrames() {
        accountStateFrameTask?.cancel()
        guard let carrier = client?.carrier as? LinkCarrier else {
            accountStateFrameTask = nil
            return
        }
        probeNote?("accountState.wire", ["observers": String(accountStateObservers.count)], false)
        accountStateFrameTask = Task { [weak self] in
            let raw = await carrier.accountStateStream()
            for await keys in raw {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.probeNote?("accountState.frame",
                                ["keys": keys.joined(separator: ","),
                                 "observers": String(self.accountStateObservers.count)], false)
                for continuation in self.accountStateObservers.values {
                    continuation.yield(keys)
                }
            }
        }
    }
}
