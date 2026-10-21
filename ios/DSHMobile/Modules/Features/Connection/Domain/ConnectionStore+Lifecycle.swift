import DSHKit
import Foundation

/// 链路生命周期：状态流、socket 三态、心跳/退避看护与前台恢复。
/// connect 仍留在 ConnectionStore 主文件；这里只处理“已连接后的守护”。
extension ConnectionStore {

    func observeStatus(of link: LinkCarrier) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await status in await link.statusStream() {
                guard let self else { return }
                if !status.online, self.state.isConnected {
                    self.state = .connecting(status.info == nil
                        ? "连接中断，正在重连…"
                        : "电脑端连接器已离线，正在等待…")
                } else if status.online, self.state.isConnecting, self.client != nil {
                    // Back online: say so. Only ever setting the offline side
                    // left the app on "正在等待…" forever after a blip, which on
                    // a phone is every trip to the background.
                    self.state = .connected(hostHome: self.hostHome)
                }
            }
        }
        // socket 三态（T005b）：Carrier 自愈成功（`.up`）时立刻探活重装，
        // 不必等下一个 2 秒探活周期——恢复延迟从"最坏 2 秒"缩到"即刻"。
        socketStateTask?.cancel()
        socketStateTask = Task { [weak self] in
            for await socketState in await link.socketStateStream() {
                guard let self else { return }
                guard socketState == .up, !self.state.isConnected,
                      let client = self.client,
                      let carrier = self.carrier as? LinkCarrier, carrier === link,
                      let profile = self.activeProfile
                else { continue }
                await self.probeHost(client: client, carrier: carrier, profile: profile)
            }
        }
    }

    // MARK: - Keeping the link honest

    /// How often a connected link is asked something cheap.
    ///
    /// A phone's link can die with nothing in flight — a Wi-Fi handover, a
    /// sleeping router, a relay restart — and the app would happily keep showing
    /// 已连接 over a dead socket. Twenty seconds is short enough that the user
    /// finds out from the chip rather than from a failed action.
    /// Watches the link and puts it back when it goes away.
    ///
    /// Two jobs in one loop, because they are the same question asked at two
    /// moments. While connected it probes the host, so a silently dead link
    /// becomes a state the UI can show instead of a lie. While disconnected it
    /// repairs the link with backoff — the relay socket heals itself, but only
    /// the store knows whether the *host* is answering again, and only the store
    /// can hand the screens a new client once it is.
    /// 心跳探活的周期（已连接时）。
    // 探活节拍的真值在 DSHKit（`LinkSupervisor.Policy`：已连接 20s / 未连接 2s）——
    // 本文件里不再留第二份常量。
    /// 未连接时的探活周期：Carrier 自愈通常在一两秒内完成，探得太慢恢复就慢。


    /// Watches the link and puts it back when it goes away.
    ///
    /// **重连只有一个所有者**（spec 022 FR-005）：socket 掉了由 `LinkCarrier` 自己按
    /// `ReconnectPolicy` 自愈，Store 在 carrier 还活着时**不建新 socket**——2026-10-13 的
    /// 每秒重连风暴就是两边各自建 socket、互相顶掉造成的（85 次 `app.dial`、12 次"上一个
    /// 还开着就再接入"）。Store 只做两件事：探活（`_link/hello`，轻量、不搬列表），
    /// 以及链路回来之后把 client 重新装上。
    ///
    /// 只有没有 carrier 时（首次连接、换档案、carrier 已关闭）才由 Store 拨号，
    /// 这时才用 `backoff`，避免"主机整夜关着"变成一秒一次的请求。
    func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeProfile != nil else { break }

                if let client = self.client, let carrier = self.carrier,
                   let profile = self.activeProfile ?? self.preferredProfile {
                    // 已连接：慢心跳探活；未连接：快探活等 Carrier 自愈回来。
                    let interval = self.supervisor.probeInterval(isConnected: self.state.isConnected)
                    try? await Task.sleep(for: .seconds(interval))
                    if Task.isCancelled { break }
                    await self.probeHost(client: client, carrier: carrier, profile: profile)
                    continue
                }

                // 没有 carrier：这才轮到 Store 拨号。
                if let connectedAt = self.connectedAt {
                    // 上一条链路活了多久，决定退避是否清零（FR-001）。
                    // 顺序与相位都在 LinkSupervisor 里钉住了：先 note（把"活了多久"交给退避），
                    // 再取 delay——所以第一次失败后等的是 2 秒（见 DSHKit 的 LinkSupervisorTests）。
                    _ = self.supervisor.noteLinkEnded(livedFor: Date().timeIntervalSince(connectedAt))
                    self.connectedAt = nil
                }
                // 只读，不推进：推进已经在上面那次 `noteLinkEnded` 里做过。
                let delay = self.supervisor.nextDelay
                await self.linkDiagnostics.record(kind: "link.backoff", detail: [
                    "attempt": .int(self.supervisor.attempt),
                    "nextMs": .int(Int(delay * 1000)),
                    "reason": .string("store-dial"),
                ])
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { break }
                guard !self.isConnecting,
                      let profile = self.activeProfile ?? self.preferredProfile,
                      let secret = Keychain.get(profile.secretAccount)
                else { continue }
                // 后台恢复路径：同目标的在飞拨号直接复用（US3 AC1），不另起一拨。
                await self.connectSingleFlight(profile: profile, secret: secret, join: true)
            }
            self?.watchTask = nil
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    /// Reconnects the profile that was in use, if the link has dropped.
    ///
    /// 冷启动时沿用上次那台电脑：把最近用过的 profile 设为活动，然后照常去连。
    ///
    /// 为什么要有这一步：列表页只在"有活动连接"之后才出现，于是冷启动永远先落在
    /// 连接页——手机上有缓存也只能干等用户点一下「连接」。用户要的是微信那种
    /// "打开就是上次的样子"，所以启动就把上次那台电脑认下来：连上了直接是实时数据，
    /// 连不上也是**列表 + 缓存行 + 未连接提示**，而不是一个空白的选择页。
    ///
    /// - Returns: 是否认下了某个 profile（没有历史/没有密钥时为 false，仍然显示连接页）。
    @discardableResult
    public func adoptPreferredProfile() -> Bool {
        guard activeProfile == nil else { return true }
        guard let profile = preferredProfile else {
            // 没有可用的历史（首次安装、或密钥被清）：仍然显示连接页。留一行日志，
            // 排查"为什么没直接进列表"时不用再猜。
            return false
        }
        activeProfile = profile
        state = .connecting("正在连接…")
        return true
    }

    /// Called when the app returns to the foreground. iOS suspends a backgrounded
    /// app and its sockets with it, so the link is often dead by the time the
    /// user looks again — this is what puts it back without asking them to pair
    /// again. Repairing rather than replacing is what keeps the current screen
    /// current: see `connect(profile:secret:)`.
    public func reconnectIfNeeded() async {
        guard !state.isConnected, !isConnecting, !isReconnecting else { return }
        guard let profile = activeProfile ?? preferredProfile else { return }
        // 用户主动动作：不等退避（FR-002）。
        supervisor.reset()
        await connect(to: profile)
    }

    /// - Parameter invalidateConnects: 外部（用户/换档案）调用必须为 `true`：把在飞的
    ///   connect 取消并使它的 `install()` 弃权；`performConnect` 内部的换档案清理传
    ///   `false`，否则会把刚起步的自己一并作废。
}
